#lang scribble/lp2/manual
@require[@for-label[racket/base]]

@title{A practical example of kill-safe, concurrent programming in Racket}
@author{Nikhil Marathe}

@hyperlink["https://racket-lang.org"]{Racket's} default concurrency model is based on green threads. It uses a model based on ConcurrentML (CML), which is very similar to Go, but allows further composition of concurrency primitives. In @hyperlink["https://nikhilism.com/post/2023/racket-beyond-languages/#concurrentml-inspired-concurrency"]{one of my posts} I had given a quick summary of this and pointers to other resources. I thought it would be good to walk through building a somewhat useful concurrent program to show how to use it. As an experiment, this is written as a literate program, using @hyperlink["https://docs.racket-lang.org/scribble-lp2-manual/index.html"]{scribble/lp2/manual}

Beyond the use of ConcurrentML primitives, which allow dynamically building up sets of events to wait on, and associating actions to run when those events are @emph{selected}, this program also demonstrates @hyperlink["https://users.cs.utah.edu/plt/publications/pldi04-ff.pdf"]{kill-safety}. That is, the program should exhibit liveness and safety in the presence of subprocess exits, or various other threads terminating.

This tutorial assumes some familiarity with Racket, Go-style concurrency (including @hyperlink["https://gobyexample.com/channels"]{channels}), green threads, Git and running subprocesses.

The use case is to provide a Racket wrapper for @hyperlink["https://git-scm.com/docs/git-cat-file"]{git-cat-file}. Imagine a task that requires getting the contents of a specific file in a Git repository at a specific commit. A common uses case includes generating some code from the contents at a specific commit.

To avoid subprocess overhead the program will use @code{cat-file}'s @emph{batch mode}. This batch execution will be wrapped in a @racket[catter], and multiple threads can concurrently request the contents of files at various commits.

@section{The catter API}

A user creates a catter using @racket[make-catter]. The returned catter can be safely used from multiple threads.

@chunk[<make-catter>
       (define (make-catter repo-path)
         <make-catter-body>)]

The catter can be stopped via custodian shutdown, or using @racket[catter-stop!].

@chunk[<catter-stop>
       (define (catter-stop! a-catter)
         <catter-stop-body>)]

There are 2 ways to submit read requests. The blocking @racket[catter-read], which will return the contents of the file, as a @racket[byte-string] (or raise an error),

@chunk[<catter-read>
       (define (catter-read cat commit file-path)
         <catter-read-body>)]

and @racket[catter-read-evt]

@chunk[<catter-read-evt>
       (define (catter-read-evt cat commit file-path)
         <catter-read-evt-body>)]

which offers a @emph{synchronizable event} that can be waited on with other events. This will become @emph{ready for synchronization} when the file content is available, and the @emph{synchronization result} is the file contents. For example, the consumer could @racket[sync] on this with a @racket[alarm-evt] to do something else if a response is not received within a given time.

Here is a complete example of using @racket[catter]. TODO: Use a different repo. It hard-codes a few different files, and gets their content at a specific commit, but in different threads.

@chunk[<example>
       (define (do-stuff-with-file file-path contents)
         (printf "~a contents ~a~n" file-path contents))

       (define files
         (list
          "content/post/2023/canadian-express-entry-experience.md"
          "content/post/2023/gossip-glomers-racket.md"
          "content/post/2023/gradient-descent-racket.m"
          "content/post/2023/making-sense-of-continuations.md"
          "content/post/2023/nuphy-air75-wireless-linux.md"
          ))

       (define commit "688600a4be5f016acfbf6c191562913b490ed687")

       (define cat (make-catter "/home/nikhil/nikhilism.com"))
       (define tasks 
         (for/list ([file files])
           (thread
            (lambda ()
              (do-stuff-with-file file (catter-read cat commit file))))))
       (map sync tasks)
       (catter-stop! cat)]

@section{Design}

The @racket[catter] manages a @code{git-cat-file} @racket[subprocess]. Requests for file contents need to be written to the stdin of the subprocess, and responses are read from stdout. Responses have a specific pattern: a single line with response metadata, a new line, then the contents, then a new line. To avoid having to juggle this state of where we are, we will have a dedicated @deftech{reader thread} to read stdout. Just like @emph{goroutines}, Racket @racket[thread]s are very cheap to create and are pre-emptible.

Besides managing the subprocess, the @racket[catter] has to handle incoming requests, and deliver responses to the correct calling thread. The implementation will make liberal use of @racket[channel]s for this, as these are also cheap to create. Channels are always synchronous (like CML). They don't @emph{contain} values. Rather, they act as emph{synchronization points} where threads can @emph{rendezvous} and exchange a single value. If you really need bounded, buffered channels, those are present in the standard library.

To perform all this management, the @racket[catter] has a @deftech{manager thread} that spins forever. The @tech{manager thread} is the heart of @racket[catter], and exhibits the kill safety characteristics we want.

@section{Creating the catter}

To help debug the code, lets define a helper logger

@chunk[<logger>
       (define-logger git-cat)]

This defines a logger named @code{git-cat}, and several helper functions like:

@racketblock[(log-git-cat-debug "Debug log")
             (log-git-cat-info "Info log")]

Both the Dr. Racket Log window and the terminal will show log output based on the log level. This can be set to @code{debug} by setting the environment variable @code|{PLTSTDERR="debug@git-cat"}|, or making a similar change in the Dr. Racket Log window.

@racket[catter] is a struct. @code{req-ch} is a @racket[channel] for incoming requests. @code{stop-ch} is a channel to tell the catter to stop (only used by @racket[catter-stop!]) and @code{mgr} is the @tech{manager thread}.

@chunk[<catter-struct>
       (struct catter (req-ch stop-ch mgr))]

The @racket[catter] constructor is really simple. It creates the two channels and the manager thread, and returns a @racket[catter] instance with its fields set.

@chunk[<make-catter-body>
       (define req-ch (make-channel))
       (define stop-ch (make-channel))
       (catter req-ch stop-ch (make-manager repo-path req-ch stop-ch))]

@racket[make-manager] creates a new instance of the @tech{manager thread}, which is the most complex part of the program. We are going to break it down into somewhat bite-size pieces.

@chunk[<make-manager>
       (define (make-manager repo-path req-ch stop-ch)
         (thread/suspend-to-kill
          (lambda ()
            <subproc-creation>

            <reader-setup>
            
            <manager-loop>)))]

The use of @racket[thread/suspend-to-kill] is crucial. Unlike a thread created with @racket[thread], this suspend-to-kill thread is not actually terminated by @racket[kill-thread] or @racket[custodian-shutdown-all]. It remains suspended and can be resumed by @racket[thread-resume]. This prevents rogue users of @racket[catter] from denying service to other @racket[thread]s. It also prevents deadlock from mistaken use. In this admittedly contrived situation

@racketblock[(define cat (make-catter ...))
             ; give the catter to another thread.
             (thread
              (lambda ()
                (sleep 5)
                (catter-read ...)))
             ; oops! stopped
             (catter-stop! cat)]

a naive implementation would lead to the second thread never receiving a response, as @racket[catter-read] would submit a request, but the manager thread would be dead. A suspended thread will only truly terminate when there are no references to it any longer.

@subsection{Creating the subprocess}

@chunk[<subproc-creation>
       (define-values (cat-proc proc-out proc-in _)
         (parameterize ([current-subprocess-custodian-mode 'kill])
           ; current-error-port is not a valid file-stream-port? when run in DrRacket.
           ; this is dumb because we are losing
           (let ([err-port (if (file-stream-port? (current-error-port))
                               (current-error-port)
                               (let ([fn (make-temporary-file "rkt_git_cat_stderr_~a")])
                                 (log-git-cat-debug "stderr is not a file-stream. Using ~a instead." fn)
                                 (open-output-file fn #:exists 'truncate)))])
             (subprocess #f #f err-port
                         (find-executable-path "git")
                         "-C" repo-path
                         "cat-file"
                         "--batch=%(objectname) %(objecttype) %(objectsize) %(rest)"))))
       
       (file-stream-buffer-mode proc-in 'line)]

This part is fairly easy. I won't explain the work-around for Dr. Racket. We use @racket[subprocess] to spawn @code{git cat-file}, passing a few parameters. The crucial one is the @code{--batch=} format string. The @code{%(rest)} bit request's that anything in the input request following the object name is reflected back in the response. This allows delivering file contents to the correct read request. The parameterization of @racket[current-subprocess-custodian-mode] ensures the process is forcibly killed on custodian shutdown. This does mean that if any thread creates the @racket[catter] within a custodian and shuts down the custodian, any threads spawned outside the custodian, that use the catter, will receive a non-functional catter. However our kill-safe design will still make sure those threads don't block. Finally, we set the stdin mode to line buffered. This way the port implementation will automatically flush when we write a line, saving us some effort.

@subsection{Reader setup}

This is pretty simple, with the actual details in the relevant section (TODO: Link).
@chunk[<reader-setup>
       (define reader-resp-ch (make-channel))
       (define reader (make-reader proc-out reader-resp-ch))]

The @code{reader-resp-ch} channel is used to read responses from the reader thread. It will be ready for synchronization whenever the reader has file contents or errors.

Let's digress to the reader thread for a bit, before diving into the meat of the implementation.

@section{The Reader}

The reader is a regular thread, since kill-safety doesn't require it to stay suspended. It will read @code{git-cat-file} batch output and put a response on the @code{resp-ch}. We @racket[parameterize] the input port so that all read operations can default to the @racket[current-input-port] instead of requiring @code{proc-out} to be passed to each one.

@chunk[<make-reader>
       (define (make-reader proc-out resp-ch)
         (thread
          (lambda ()
            ; TODO: Can the key have whitespace?
            (parameterize ([current-input-port proc-out])
              <reader-loop>))))]

The reader loop is fairly straightforward
@chunk[<reader-loop>
       (let loop ()
         (define line (read-line))
         (when (not (eof-object? line))
           (match (string-split line)
             [(list object-name "blob" object-len-s key)
              (define object-len (string->number object-len-s))
              (define contents (read-bytes object-len))
              (if (= (bytes-length contents) object-len)
                  ; consume the newline
                  (begin
                    (read-char)
                    (channel-put resp-ch (cons key contents))
                    (loop))
                  ; subproc must've exited/catter stopped.
                  (error 'unexpected-eof))]
             ; (or ...) doesn't allow introducing sub-patterns to match against, so use regexp.
             <error-handling>)))]

It tries to read one line, which is assumed to be the metadata line. This is split by whitespace and matched to the @code{"blob"} output. This indicates we got successful file contents, in which case we can use @racket[match]'s powerful ability to introduce bindings to access the various metadata. We do make sure to read exactly the file contents. If we are unable to do this, something is wrong (the subprocess exited), and we error. Otherwise the key and contents are written out to the channel.

We must also handle some error cases in the batch output. These can happen if the input commit/file-path combination was invalid. Unlike end-of-file, these are user errors and should be relayed to the caller. So we match those forms, and then create an @racket[exn:fail] object with some extra information. That is written out to the channel, with other parts of the API knowing how to handle exceptions.

@chunk[<error-handling>
       [(list object-name (regexp #rx"^missing|ambiguous$" msg))
        (channel-put resp-ch
                     ; In case of missing, the returned object-name is what we passed in, so it can be used as the key.
                     (cons object-name
                           (exn:fail
                            (format "~a object ~v" (car msg) object-name)
                            (current-continuation-marks))))
        (loop)]]

@section{Scratch}


@chunk[<manager-loop>
       (let loop ([pending null]
                  [write-requests null]
                  [response-attempts null]
                  [closed? #f])
         (apply
          sync
          ; New file path. send to reader.
          (handle-evt req-ch
                      (match-lambda
                        [(Request commit path resp-ch nack-evt)
                         (if closed?
                             (loop pending
                                   write-requests
                                   (cons
                                    (Response-Attempt resp-ch nack-evt (exn:fail "catter stopped" (current-continuation-marks)))
                                    response-attempts)
                                   closed?)
                             (let* ([key (format "~a:~a" commit path)]
                                    [p (Pending key resp-ch nack-evt)]
                                    ; everything after the first whitespace in the input is replaced in the %(rest)
                                    ; in the output. Use this to correlate the key.
                                    [write-req
                                     (string->bytes/utf-8 (format "~a ~a~n" key key))])
                               (loop (cons p pending)
                                     (cons write-req write-requests)
                                     response-attempts
                                     closed?)))]))

          (handle-evt reader-resp-ch
                      (match-lambda
                        [(cons got-key contents)
                         ; not sure if there is an elegant way to avoid this mutation.
                         (define found #f)
                         (define new-pending
                           (filter
                            (lambda (p)
                              (if (and (not found) (equal? got-key (Pending-key p)))
                                  (begin
                                    (set! found (pending->response p contents))
                                    #f)
                                  #t))
                            pending))
                         (loop new-pending
                               write-requests
                               (if found
                                   (cons found response-attempts)
                                   response-attempts)
                               closed?)]))

          ; once the subproc is dead, some of these events will always be "ready".
          ; avoid looping forever on them.
          ; this is correct because this is the only case that sets closed? to true.
          (if closed?
              never-evt
              (handle-evt (choice-evt cat-proc reader stop-ch)
                          (lambda (_)
                            (close-output-port proc-in)
                            (subprocess-wait cat-proc)
                            (define status (subprocess-status cat-proc))
                            (when (not (zero? status))
                              (log-git-cat-error "subprocess exited with non-zero exit code: ~a" status))
                            (define new-puts
                              (map
                               (curryr pending->response (exn:fail "terminated" (current-continuation-marks)))
                               pending))
                            (loop null
                                  null
                                  (append new-puts response-attempts)
                                  #t))))
       
          (append
           (for/list ([req (in-list pending)])
             (handle-evt (Pending-nack-evt req)
                         (lambda (_)
                           (loop (remq req pending)
                                 write-requests
                                 response-attempts
                                 closed?))))
         
           (for/list ([req (in-list write-requests)])
             (handle-evt (write-bytes-avail-evt req proc-in)
                         (lambda (_)
                           (loop pending (remq req write-requests) response-attempts closed?))))
         
           (for/list ([res (in-list response-attempts)])
             (match-let ([(Response-Attempt ch nack-evt response) res])
               (handle-evt (choice-evt (channel-put-evt ch response) nack-evt)
                           (lambda (_)
                             (loop pending
                                   write-requests
                                   (remq res response-attempts)
                                   closed?))))))))]

@chunk[<catter-stop-body>
       (thread-resume (catter-mgr a-catter) (current-thread))
       (channel-put (catter-stop-ch a-catter) 'stop)]

@chunk[<catter-read-body>
       (sync (catter-read-evt cat commit file-path))]

@chunk[<catter-read-evt-body>
       ; in case the caller thread goes away, the nack-evt will become ready.
       ; this allows the catter to remove callers no longer awaiting responses.
       (define evt (nack-guard-evt
                    (lambda (nack-evt)
                      ; response will go here
                      (define resp-ch (make-channel))
                      ; ensure the manager starts running with our custodian chain.
                      (thread-resume (catter-mgr cat) (current-thread))
                      ; send the request.
                      (channel-put (catter-req-ch cat) (Request commit file-path resp-ch nack-evt))
                      resp-ch)))
       (handle-evt evt
                   (lambda (resp)
                     (if (exn:fail? resp)
                         (raise resp)
                         resp)))]

@chunk[<*>
       (require racket/file)
       (require racket/function)
       (require racket/match)
       (require racket/string)

       <logger>

       <catter-struct>

       (struct Request (commit path ch nack-evt))
       (struct Pending (key ch nack-evt))
       (struct Response-Attempt (ch nack-evt resp))

       (define (pending->response p resp)
         (Response-Attempt (Pending-ch p)
                           (Pending-nack-evt p)
                           resp))

       <make-reader>

       <make-manager>

       <make-catter>

       <catter-stop>
       
       <catter-read>

       <catter-read-evt>

       <example>]

