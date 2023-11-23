#lang scribble/lp2/manual
@require[@for-label[racket/base]]

@title{A practical example of kill-safe, concurrent programming in Racket}
@author[(author+email "Nikhil Marathe" "me@nikhilism.com" #:obfuscate? #t)]

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

The reader loop is fairly straightforward.

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

While @racket[match] provides an @code{or} matcher, it doesn't allow binding the match to an identifier. We need the message so we can tell the caller what happened, so we use a @racket[regexp] matcher.

@chunk[<error-handling>
       [(list object-name (regexp #rx"^missing|ambiguous$" msg))
        (channel-put resp-ch
                     ; In case of missing, the returned object-name is what we passed in, so it can be used as the key.
                     (cons object-name
                           (exn:fail
                            (format "~a object ~v" (car msg) object-name)
                            (current-continuation-marks))))
        (loop)]]

All other exceptions will cause the reader to fail, and the manager will observe that.

@section{The Manager}

This is the crux of the program. We are going to continue from where we left off in @code{<make-manager>}. We will observe several useful features of the CML model here.

The main standout is @racket[sync], which blocks on an entire sequence of events, and proceeds
when @emph{exactly one of them} is ready for synchronization. TODO: Link to andy wingo explanation of how this is done. Unlike Go's @code{select} statement, the sequence can be built up dynamically.

The other is useful primitives like @racket[handle-evt] that allow us to associate behaviors with events, while preserving composition.

@margin-note{Technically, Go has @hyperlink["https://pkg.go.dev/reflect#Select"]{reflect.Select()} which allows a list of cases, but I don't think it is widely used in practice.}

@subsection{The Manager Loop}

The manager is an infinite loop that maintains 3 lists and a boolean.

@itemlist[#:style 'ordered
          @item{@code{pending} is a list of @racket[Pending] instances, tracking outstanding @code{cat-file} requests that have been accepted and for whom we are awaiting a response from the subprocess.}
          @item{@code{write-requests} is a list of @racket[bytes] containing UTF-8 encoded lines we want to write to the subprocesses' standard input. I'll explain why this exists below.}
          @item{@code{response-attempts} is a list of @racket[Response-Attempt]s. On each loop iteration we will try to send a response back to the thread that issued the request.}
          @item{@code{closed?} a boolean that tracks whether this catter is no longer operational, due to clean shutdown or error.}]

The structs in these lists are:

@chunk[<useful-structs>
       (struct Request (commit path ch nack-evt))
       (struct Pending (key ch nack-evt))
       (struct Response-Attempt (ch nack-evt resp))

       (define (pending->response p resp)
         (Response-Attempt (Pending-ch p)
                           (Pending-nack-evt p)
                           resp))]

@racket[Request]s are passed to the manager thread by @code{<catter-read-evt>}.

@racket[Pending] tracks the key associated with the request, the channel the calling thread expects a response on, and a @emph{negative acknowledgement} (NACK) event, which will be used for cancellation.

Once the subprocess returns a response, a @racket[Pending] request becomes a @racket[Response-Attempt], using the @racket[pending->response] helper. @code{resp} is either a @racket[bytes] containing the file contents or an @racket[error].

The loop itself is a single call to @racket[sync]. However each event in the call has some complexity, so the overall code is long. Let's look at it one at at time. @bold{The one invariant we must preserve is that @code{loop} always calls itself regardless of which event gets selected}.

We use @racket[apply] plus @racket[append] to assemble the various combinations of single events and lists that we need to pass to @racket[sync]. This means @racket[sync] may be waiting on tens of events at once. Each event is going to have extra behavior associated with it using @racket[handle-evt], all of which promise to call the loop again.

@chunk[<manager-loop>
       (let loop ([pending null]
                  [write-requests null]
                  [response-attempts null]
                  [closed? #f])
         (apply
          sync
          
          <new-request>
          <reader-response>
          <stop>
          (append
           <pending-requests>
           <submit-inputs>
           <response-attempts>)))]

To restate, each iteration of the loop, @racket[sync] will pick @emph{one} event out of any that are ready for synchronization. It will return the synchronization result of that event. Our events are actually wrapper events returned by @racket[handle-evt]. This means, when the wrapped event is ready for synchronization, the wrapper is also ready. However, the synchronization result of the event from @racket[handle-evt] is the return value of the function provided as the second argument of @racket[handle-evt]. Due to Racket's tail call optimizations, it is safe and fast for these functions to call @code{loop} as long as it is done in tail position.

@subsection{Handling a new request}

@chunk[<new-request>
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
                                 [write-req
                                  (string->bytes/utf-8 (format "~a ~a~n" key key))])
                            (loop (cons p pending)
                                  (cons write-req write-requests)
                                  response-attempts
                                  closed?)))]))]

When we receive a new request from other threads, it will come in on the @code{req-ch} channel as a @racket[Request]. The synchronization result of a channel is the value received on the channel. We can use the convenient @racket[match-lambda] to directly create a function that will bind to the members of the struct.

If the catter is already closed, we don't create a pending request. Instead we queue up a response attempt to the calling thread and continue looping. This handles the kill-safety aspect, where callers can continue to rely on the catter responding to them, as long as they have a reference to it.

In the common case where the catter is running, we create a key using the commit and path. We do this because the object name of the response will not be the commit+file path, so we need a way to associate the request and response. The key is also the input request object name. We rely on @code{cat-file}'s input syntax treating everything after the object name as something that will be echoed back in the @code{%(rest)} output format. We loop with this request line ready to be written.

@margin-note{TODO: Note about how key is not strictly required.}

@subsection{Handling responses from the Reader}

The next possible event is the reader responding with a @racket[pair] of the key and contents. Handling it is straightforward. This handler tries to find an entry in pending that matches the key. It creates a @racket[Response-Attempt] from that, and then removes it from the pending list (by returning @racket[#f] to the @racket[filter]). It loops again with the two modified lists.

@margin-note{If anybody knows how to express the @racket[filter] in a nicer way, please tell me!}

@chunk[<reader-response>
       (handle-evt reader-resp-ch
                   (match-lambda
                     [(cons got-key contents)
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
                            closed?)]))]

@subsection{Events that stop the catter}

There are 3 situations in which the catter can no longer process new requests.

@itemlist[#:style 'ordered
          @item{The subprocess exits. This could happen for a multitude of reasons, including the user killing the process or it encountering an error. The Racket @racket[subprocess] is an event that becomes ready on process exit.}
          @item{The reader thread exits, due to an 'eof or due to an error. @racket{thread} is ready for synchronization in that case.}
          @item{An explicit stop via @racket[catter-stop!].}]

In all 3 cases, we want to do the same thing, so we compose @racket[choice-evt] and @racket[handle-evt]. This is pretty neat!

Closing the subprocess input port is essential to cause the subprocess to quit. Then we wait for the process to quit and log an error if it did not exit successfully. At this point, any pending requests cannot be fulfilled. They get converted to @racket[Response-Attempt]s with an exception as the result. The next loop also discards all attempts to write to @code{proc-in} as those will no longer succeed. @bold{The most important action is to set @code{closed?} to @racket[#t]}.

@chunk[<stop>
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
                               #t))))]

@subsection{Safely handling callers that have gone away}

This is the first case where we are going to do something that will seem weird, but is surprisingly powerful. I'm also not sure if a facility like this truly exists in other concurrency implementations. We are going to handle the case where a caller submitted a request, but then disappeared before receiving the response. It either is no longer interested, or experienced some error and terminated. Regardless, we don't want to keep the request attempt pending on the manager end. We are going to leverage negative acknowledgement events here. See the TODO:Link section on the public API for how we acquired a nack event. On this end, what is important is that the nack event will become ready regardless of how the calling thread went away. We can use it to safely remove the pending request. Note that the catter will still submit the request to the subprocess. We are only using this to discard responses. We will see another appearance from nack events in the response-attempts handler TODO: Link section, where it will be more important.

@margin-note{Removing any requests that are not yet sent to the subprocess from @code{write-requests} is left as an exercise for the reader ;-).}

TODO: Contrast to Python and Go

@chunk[<pending-requests>
       (for/list ([req (in-list pending)])
         (handle-evt (Pending-nack-evt req)
                     (lambda (_)
                       (loop (remq req pending)
                             write-requests
                             response-attempts
                             closed?))))]

@subsection{Submitting requests to the subprocess}

@chunk[<submit-inputs>
       (for/list ([req (in-list write-requests)])
         (handle-evt (write-bytes-avail-evt req proc-in)
                     (lambda (_)
                       (loop pending (remq req write-requests) response-attempts closed?))))]

One of the things to keep in mind when writing concurrent code is that we have to correctly handle any action that could cause the thread to block. Racket is communicating with the subprocess over pipes, and pipes have a limited capacity. The process on either end can block once this capacity is reached. If the subprocess is waiting for the reader thread to read from stdout, then it can block on stdin. This would be bad for the manager thread because it would not be able to service new incoming requests until that was resolved. Any and all actions in our loop should execute fast and re-enter the @racket[sync]. This is why, in TODO: Link the handling a new request section, we didn't try to write to the subprocess in the event handler. In this chunk of code, we use @racket[write-bytes-avail-evt] instead. This will only become ready if it is possible to write to the pipe immediately, without blocking. If so, it will perform the write. It offers the guarantee that if the event is not selected by @racket[sync], no bytes have been written. This ensures we don't write the same request multiple times. When this write succeeds, the handler removes it from future iterations.

@subsection{Sending responses to the caller}

@chunk[<response-attempts>
       (for/list ([res (in-list response-attempts)])
         (match-let ([(Response-Attempt ch nack-evt response) res])
           (handle-evt (choice-evt (channel-put-evt ch response) nack-evt)
                       (lambda (_)
                         (loop pending
                               write-requests
                               (remq res response-attempts)
                               closed?)))))]


So far, we have been queuing reader responses into @code{response-attempts}, instead of resolving the caller's request. This is for the same reason that we aren't writing directly to the subprocess standard input. A @racket[channel] has no buffer, which means if the caller thread has gone away, a @racket[channel-put] will deadlock. Instead, we use @racket[channel-put-evt], which, similar to @racket[write-bytes-avail-evt] tries to perform the action in a way that does not block the @racket[sync], but only proceeds when it is possible to proceed. At the same time, this handler also monitors the nack event provided by the initial request. Due to how the public API will set this up, we are guaranteed that one of the two must succeed. Either the thread is still waiting on the other end, or the nack event will be ready. In either case, the handler simply removes the response attempt from future iterations. Pretty neat!

@section{Implementing the public API}

Phew! Good job on making it past the manager loop. There are still a couple of confusing things in there. Hopefully, seeing the public API will make clear those up.

@chunk[<catter-stop-body>
       (thread-resume (catter-mgr a-catter) (current-thread))
       (channel-put (catter-stop-ch a-catter) 'stop)]

Stopping the catter is pretty simple. Just issue a write (doesn't matter what we write) to the channel. However, the call to @racket[thread-resume] is key! Remember how the manager thread was created with @racket[thread/suspend-to-kill] so it doesn't terminate? Well, it can still be suspended if all custodians that were managing it go away. @racket[thread-resume] associates the manager thread with the current thread, which means it acquires all the custodian requirements of the current thread. With a non-empty custodian set, the thread can start running again. This is crucial because we are about to write to a channel that better have a reader on the other end. I encourage reading the kill-safety paper for the details.

The other public APIs will similarly need to be careful to resume the thread!

@chunk[<catter-read-body>
       (sync (catter-read-evt cat commit file-path))]

The synchronous request version is easy. We take the async form and block on it.

@subsection{Using negative acknowledgements to good effect}

@chunk[<catter-read-evt-body>
       (define evt (nack-guard-evt
                    (lambda (nack-evt)
                      (define resp-ch (make-channel))
                      (thread-resume (catter-mgr cat) (current-thread))
                      (channel-put (catter-req-ch cat) (Request commit file-path resp-ch nack-evt))
                      resp-ch)))
       (handle-evt evt
                   <handle-read>)]

This function provides the nack events the manager loop has been monitoring. nack events are a core part of the Racket/CML concurrency model, and are manufactured using @racket[nack-guard-evt]. I encourage reading the documentation for @racket[guard-evt] and @racket[nack-guard-evt] carefully, and playing with them a bit, as it isn't immediately obvious what is happening. To get a response back from the manager, we are using a @racket[channel]. We want to guard against the API caller no longer waiting on the response. To do this, we wrap the channel with a nack event. The @racket[nack-guard-evt] function returns an event. Every time this event is used with @racket[sync], it calls the function passed to @racket[nack-guard-evt] with a new nack event. There are now two events in play, and they are linked.

The first event is the @emph{return value} of @racket[nack-guard-evt]. This event becomes ready when the return value of the function passed to @racket[nack-guard-evt] becomes ready. In this case, that is the channel on which the manager thread will deliver the response.

The second event is the @code{nack-evt} passed to the function. This event is sent to the manager. When (and only when!) the first event is used in a @racket[sync], but is @emph{not} chosen as the result of the @racket[sync], the nack event will become ready. If the first event @emph{is} chosen, then the nack event will @emph{never} become ready. This duality plays very nicely with the manager thread in TODO: link to sending responses to the caller.

Finally, in true CML form, we can compose this existing composition with @racket[handle-evt] to raise an exception or deliver the result based on the response from the manager.

@chunk[<handle-read>
       (lambda (resp)
         (if (exn:fail? resp)
             (raise resp)
             resp))]

Keep in mind that these functions, and @racket[handle-evt] are not immediately running any code. They are associating code to be run when events are passed to @racket[sync].

With that, we have completed the entire public API. I hope this gave you a taste of concurrency using Racket's CML primitives.

@section{Complete Code}

Some imports round off the program. Also see @hyperlink["https://github.com/nikhilm/git-catter/blob/master/main.rkt"]{the full listing}. 

@chunk[<*>
       (require racket/file)
       (require racket/function)
       (require racket/match)
       (require racket/string)

       <logger>

       <catter-struct>

       <useful-structs>

       <make-reader>

       <make-manager>

       <make-catter>

       <catter-stop>
       
       <catter-read>

       <catter-read-evt>

       <example>]

@section{References and acknowledgements}


@section{Additional thoughts}

Readability of the long manager loop. Pattern of changing a couple of things, and leveraging immutability is nice. CML composition would allow splitting up into functions, but the need to keep the loop around renders this a little contrived.

Cases in which thread-resume can still fail (if the manager threw an exception and terminated) and what to do about that.

Bounded vs unbounded channels.

Comparison to Erlang, Python, Go.
