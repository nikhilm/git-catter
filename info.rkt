#lang info
(define collection "git-catter")
(define deps '("base"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib" "scribble-lp2-manual"))
(define scribblings '(("scribblings/git-catter.scrbl" ())))
(define pkg-desc "A tutorial on using Racket concurrency primitives for a practical program")
(define version "0.1")
(define pkg-authors '(racket-packages@me.nikhilism.com))
(define license '(MIT))
