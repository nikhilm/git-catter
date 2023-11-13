#lang racket

(define-logger git-cat)

(struct catter (req-ch mgr))

(struct Request (commit path ch nack-evt))
(struct Pending (key ch nack-evt))
(struct Response-Attempt (ch nack-evt resp))

(define (pending->response p resp)
  (Response-Attempt (Pending-ch p)
                    (Pending-nack-evt p)
                    resp))

; reader is a separate thread since it has to preserve some state implicitly to know whether to read the header or the contents.
(define (make-reader proc-out resp-ch)
  (thread
   (lambda ()
     ; TODO: Can the key have whitespace?
     (parameterize ([current-input-port proc-out])
       (let loop ()
         (define line (read-line))
         (when (not (eof-object? line))
           (match (string-split line)
             [(list object-name "blob" object-len-s key)
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
                  ; subproc must've exited.
                  ; just error out here.
                  ; the manager will notice the thread dying and notify all pending requests.
                  (error 'unexpected-eof))
              ]
              ; TODO: Handle missing
             [_
              (log-git-cat-error "Match failed for ~a" line)
              ; TODO: Handle the case where we get non-matching but not EOF for some reason
              ; reloop to handle eof.
              (loop)])))))))

(define (make-manager repo-path req-ch)
  (thread/suspend-to-kill
   (lambda ()
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
                       ; TODO: Lookup from PATH.
                       "/usr/bin/git"
                       "-C" repo-path
                       "cat-file"
                       "--batch=%(objectname) %(objecttype) %(objectsize) %(rest)"))))

     (file-stream-buffer-mode proc-in 'line)
     (define reader-resp-ch (make-channel))
     (define reader (make-reader proc-out reader-resp-ch))

     (let loop ([pending null]
                [write-requests null]
                [response-attempts null]
                [closed? #f])
       (apply
        sync
        ; -> new file path. send to reader
        (handle-evt req-ch
                    (match-lambda
                      [(Request commit path resp-ch nack-evt)
                       (log-git-cat-debug "Got a new request")
                       (if closed?
                           (loop pending
                                 write-requests
                                 (cons
                                  (Response-Attempt resp-ch nack-evt (exn:fail "catter stopped" (current-continuation-marks)))
                                  response-attempts)
                                 closed?)
                           (begin
                             ; This does assume the file path is printable.
                             (let* ([key (format "~a:~a" commit path)]
                                    [p (Pending key resp-ch nack-evt)]
                                    ; everything after the first whitespace in the input is replaced in the %(rest)
                                    ; in the output. Use this to correlate the key.
                                    [write-req
                                     (string->bytes/utf-8 (format "~a ~a~n" key key))])
                               (loop (cons p pending)
                                (cons write-req write-requests)
                                response-attempts
                                closed?))))]))

        (handle-evt reader-resp-ch
                    (match-lambda
                      [(cons got-key contents)
                       (log-git-cat-debug "Got a response ~a" got-key)
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

        ; once the subproc is dead, these events will always be "ready"
        ; avoid looping forever on them
        ; this is correct because this is the only case that sets closed? to true.
        (if closed?
            never-evt
            (handle-evt (choice-evt cat-proc reader)
                        (lambda (_)
                          (close-output-port proc-in)
                          (close-input-port proc-out)
                          (subprocess-wait cat-proc)
                          (define status (subprocess-status cat-proc))
                          (when (not (zero? status))
                            (log-git-cat-error "subprocess exited with non-zero exit code: ~a" status))
                          (define new-puts
                            (map
                             (λ (p)
                               (pending->response p (exn:fail "terminated" (current-continuation-marks))))
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
                         (log-git-cat-debug "Wrote to cat-files stdin ~a" req)
                         (loop pending (remq req write-requests) response-attempts closed?))))
         
         (for/list ([res (in-list response-attempts)])
           (match-let ([(Response-Attempt ch nack-evt response) res])
             (handle-evt
              ; regardless of which branch gets chosen, just remove the attempt.
              (choice-evt (channel-put-evt ch response) nack-evt)
              (lambda (_)
                       (log-git-cat-info "Got resp att")
                (loop pending
                      write-requests
                      (remq res response-attempts)
                      closed?)))))))))))

(define (make-catter repo-path)
  (define req-ch (make-channel))
  (catter req-ch (make-manager repo-path req-ch)))


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
                   (channel-put (catter-req-ch cat) (Request commit file-path resp-ch nack-evt))
                   ; since the channel is a synchronization event, we can directly return it. No handle-evt required!
                   resp-ch))))
  (if (exn:fail? resp)
      (raise resp)
      resp))

; TODO: Offer a catter-stop!

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
  (define catter #f)
  (parameterize ([current-custodian (make-custodian)])
    (set! catter (make-catter "/home/nikhil/nikhilism.com"))
    (define tasks (for/list ([file files])
                    (thread
                     (lambda ()
                       (do-stuff-with-file file (catter-read catter commit file))))))
    (map sync tasks)
    (custodian-shutdown-all (current-custodian)))
  (catter-read catter commit "content/post/2023/gradient-descent-racket.md")
  void)

; TODO: Write a test where we create multiple catters in a loop. add some sleeps and intentional gcs
; make sure the previous catters (and their git-cat subproc) is correctly shut down when no refs remain.
