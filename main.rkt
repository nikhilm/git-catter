#lang racket

(define-logger git-cat)

(struct catter (req-ch mgr))

(struct Request (commit path ch nack-evt))
(struct Response (key contents))
(struct Pending (key ch nack-evt))

; reader is a separate thread since it has to preserve some state implicitly to know whether to read the header or the contents.
(define (make-reader proc-out resp-ch)
  (thread
   (lambda ()
     ; TODO: Handle match failure
     ; TODO: Can the key have whitespace?
     ; TODO: AAAAH! If the subproc is killed, the ports do not automatically start returning eof.
     ; they block instead.
     (parameterize ([current-input-port proc-out])
       (let loop ()
         (define line (read-line))
         (when (not (eof-object? line))
           (match (string-split line)
             [(list object-name "blob" object-len-s key)
              (log-git-cat-debug "Reader read ~a" key)
              (define object-len (string->number object-len-s))
              ; if we want to return a port instead of a byte-string, one option is to use
              ; copy-port + make-limited-input-port
              (define contents (read-bytes object-len))
              (if (= (bytes-length contents) object-len)
                  ; consume the newline
                  (begin
                    (read-char)
                    (channel-put resp-ch (cons key contents))
                    (loop))
                  ; subproc died? unexpected eof.
                  ; not sure if there is a good way to manufacture an exception in racket without throwing.
                  (with-handlers ([exn:fail? (lambda (e) (channel-put resp-ch (cons key e)))])
                    (error 'unexpected-eof)))
              ]
             [_
              (log-git-cat-error "Match failed for ~a" line)
              ; reloop to handle eof.
              (loop)])))))))

(define (make-manager req-ch)
  (thread
   (lambda ()
     ; TODO: How to maintain kill safety in case the subprocess raises an exception? or the reader code throws an exception?
     ; i.e. how do we prevent callers from getting blocked forever, and new callers should receive the original error
     (define-values (cat-proc proc-out proc-in _)
       (parameterize ([current-subprocess-custodian-mode 'kill])
         ; current-output-port is not a valid file-stream-port? when run in DrRacket.
         ; this is dumb because we are losing
         (let ([err-port (if (file-stream-port? (current-error-port))
                             (current-error-port)
                             (let ([fn (make-temporary-file "rkt_git_cat_stderr_~a")])
                               (log-git-cat-debug "stderr is not a file-stream. Using ~a instead." fn)
                               (open-output-file fn #:exists 'truncate)))])
           (subprocess #f #f err-port
                       "/usr/bin/git"
                       "-C" "/home/nikhil/nikhilism.com"
                       "cat-file"
                       "--batch=%(objectname) %(objecttype) %(objectsize) %(rest)"))))

     (define reader-resp-ch (make-channel))
     (define reader (make-reader proc-out reader-resp-ch))

     ; TODO: The racket docs say that the ports above must be explicitly closed.
     ; I'm not sure why that is.
     ; In this case, will the subprocess dying be enough? Is a custodian needed?
     ; 

     ; until the thread is well and truly terminated (not by kill-thread, but by lack of refs)
     ; this loop never exits due to the use of suspend-to-kill. This means the loop needs to track
     ; if the subprocess has exited, and notify new requests.
     ; the list form does allow multiple incoming requests for the same file, which a naive hash wouldn't.
     (let loop ([pending null]
                [closed? #f])
       (apply
        sync
        ; -> new file path. send to reader
        (handle-evt req-ch
                    (match-lambda
                      [(Request commit path resp-ch nack-evt)
                       (log-git-cat-info "Got a new request")
                       ; This does assume the file path is printable.
                       (define key (format "~a:~a" commit path))
                       (define p (Pending key resp-ch nack-evt))
                       (define ok-to-queue?
                         (with-handlers ([exn:fail? (lambda (e) (channel-put resp-ch e) #f)])
                           ; everything after the first whitespace in the input is replaced in the %(rest)
                           ; in the output. Use this to correlate the key.
                           ; TODO: This could block if the pipe is full. Avoid doing this here or wrap in a sync.
                           (when closed?
                             (error 'reader-terminated))
                           (fprintf proc-in "~a ~a~n" key key)
                           (flush-output proc-in)
                                   ; intentional test
                                   ; (subprocess-kill cat-proc #t)
                           #t))
                       (if ok-to-queue?
                           (loop (cons p pending) #f)
                           (loop pending #f))]))
        
        #;subproc ; -> if this exits, what do we do? does the sync on reader handle it?
        (handle-evt reader-resp-ch
                    (match-lambda
                      [(cons got-key contents)
                       (log-git-cat-debug "Got a response ~a" got-key)
                       ; ugly ugly
                       (define found #f)
                       (define new-pending
                         (filter
                          (match-lambda
                            ; if this matches, respond to it and leave it out of the list.
                            ; oh oh! we only want to respond to the first match.
                            [(Pending key resp-ch nack-evt)
                             (if (and (not found) (equal? key got-key))
                                 (begin
                                   (set! found #t)
                                   ; is it guaranteed that if nack-evt wasn't triggered, then this put won't block?
                                   ; I don't think this is guaranteed.
                                   ; TODO: Fix the issue.
                                   ; The solution might be to re-spin this loop with the response from the
                                   ; reader, with the re-spin considering a list channel-put-evt
                                   ; that is, we maintain another list in the loop, say "responses",
                                   ; which, if non-empty, we can map over and apply handle-evt to
                                   ; the responses should be a (resp-channel content) pair
                                   ; I'm not entirely sure yet how to prevent that from eventually running out
                                   ; of memory or something if the calling threads keep dying.
                                   (channel-put resp-ch contents)
                                   #f)
                                 #t)])
                          pending))
                       (loop new-pending #f)])) ; -> if this exits, what do we do?
        (handle-evt reader
                    (lambda (_)
                      ; if this is reached, the reader has exited.
                      (for ([p (in-list pending)])
                        ; TODO: Avoid blocking on put
                        (channel-put (Pending-ch p) (exn:fail "reader terminated" (current-continuation-marks))))
                      (loop null #t)))
        #;pending ; lookup response channel and send contents. handle cancellation via nacks
        ; TODO Test this
        (for/list ([req (in-list pending)])
          (handle-evt (Pending-nack-evt req)
                      (lambda (_)
                        ; remove this from the list
                        (loop (remq req pending) #f))))
        )))))

; TODO: Eventually accept repo path.
(define (make-catter)
  (define req-ch (make-channel))
  (catter req-ch (make-manager req-ch)))

(define (catter-read cat commit file-path)
  ; in case the caller thread goes away, the nack-evt will become ready.
  ; this allows the catter to remove callers no longer awaiting responses.
  (define resp (sync
                (nack-guard-evt
                 (lambda (nack-evt)
                   ; response will go here
                   (define resp-ch (make-channel))
                   ; ensure the manager starts running with our custodian chain.
                   (thread-resume (catter-mgr cat) (current-thread))
                   ; send the request.
                   ; TODO: How does this (and kill-safety in general) work when the manager thread has exited due to an exception?
                   ; channel-put will block in that case.
                   (channel-put (catter-req-ch cat) (Request commit file-path resp-ch nack-evt))
                   ; since the channel is a synchronization event, we can directly return it.
                   resp-ch))))
  (if (exn:fail? resp)
      (raise resp)
      resp))

;(define-values (proc out in err) (subprocess #f #f #f
;                                             "/usr/bin/git"
;                                             "-C" "/home/nikhil/nikhilism.com"
;                                             "cat-file" "--batch"))
;(fprintf in "~a:~a~n" "688600a4be5f016acfbf6c191562913b490ed687"  "content/post/2023/gossip-glomers-racket.md")
;(close-output-port in)
;(printf "Resp ~v~n" (read-line out))
;

(define (do-stuff-with-file file-path contents)
  (printf "~a contents ~a~n" file-path contents))


(module+ main
  ; This is a pretend program
  (define files
    (list
     "content/post/2023/canadian-express-entry-experience.md"
     "content/post/2023/gossip-glomers-racket.md"
     "content/post/2023/gradient-descent-racket.md"
     ;    "content/post/2023/kubectl-tunnel.md"
     ;    "content/post/2023/making-sense-of-continuations.md"
     ;    "content/post/2023/nuphy-air75-wireless-linux.md"
     ;    "content/post/2023/python-idiomatic-file-iteration-bad-performance.md"
     ;    "content/post/2023/racket-beyond-languages.md"
     ;    "content/post/2023/remote-dbus-notifications.md"
     ))

  (define commit "688600a4be5f016acfbf6c191562913b490ed687")

  (parameterize ([current-custodian (make-custodian)])
    (define catter (make-catter))
    (define tasks (for/list ([file files])
                    (thread
                     (lambda ()
                       (do-stuff-with-file file (catter-read catter commit file))))))
    (map sync tasks)
    (custodian-shutdown-all (current-custodian)))
  void)

; TODO: Write a test where we create multiple catters in a loop. add some sleeps and intentional gcs
; make sure the previous catters (and their git-cat subproc) is correctly shut down when no refs remain.