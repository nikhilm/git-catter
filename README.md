git-catter
==========

An example literate program to demonstrate Racket's powerful concurrency mechanisms that are based on Concurrent ML.
The rendered HTML is hosted at <https://nikhilism.com/writing/racket-concurrency/>.

This is the command to generate html to place in the source for <https://nikhilism.com>.

```
raco scribble --html +m --redirect-main "https://docs.racket-lang.org/" --dest ~/nikhilism.com/content/writing/racket-concurrency/ --dest-name index.html scribblings/git-catter.scrbl
```

This will produce a single HTML file, and associated CSS+JS files in `dest`. `+m` cross refs to the main racket docs, and `--redirect-main` points those to the official website instead of to the local installation.