# Swank Crew

Swank Crew is a distributed computation framework written in Common Lisp that
uses [Swank Client](https://github.com/brown/swank-client) to evaluate Lisp
expressions on remote hosts.

Swank Crew works with [GNU Emacs](https://www.gnu.org/software/emacs) and
[Slime](https://en.wikipedia.org/wiki/SLIME) to make developing distributed
applications easier.  Typically, you interactively develop code on a master
machine using Slime.  Code running on the master uses the Swank Crew API to
farm out work to a gang of worker machines.  If code on a worker throws an
exception, a Slime stack trace window pops up and you can interactively debug
the problem using your existing Slime connection to the master.

## The Swank Crew API

```
connect-workers                 Create a worker pool containing a set of worker
                                Lisps.
disconnect-workers              Disconnect all the workers in a worker pool.
eval-form-all-workers           Evaluate a form on all the workers in a worker pool.
eval-form-repeatedly            Evaluate a form repeatedly on the workers in a pool
                                and collect the results on the master.
eval-repeatedly-async-state     Evaluate a form repeatedly on the workers in a pool
                                while asynchronously updating the workers' state.
parallel-mapcar                 Use the workers in a worker pool to evaluate a
                                function on all the elements of a list.
parallel-reduce                 Use the workers in a worker pool to evaluate a
                                function on all the elements of a list.  As results
                                return to the master, call a function repeatedly to
                                reduce them to one value.
```

For more information, see the documentation strings for the above functions in
[master.lisp](https://github.com/brown/swank-crew/blob/master/master.lisp) and
the example code in
[swank-crew-test.lisp](https://github.com/brown/swank-crew/blob/master/swank-crew-test.lisp).

## Installation

Swank Crew functions best when used with Slime.  In order to implement the
distributed Slime debugging features described above, you must patch
[swank.lisp](https://github.com/slime/slime/blob/master/swank.lisp) in the
directory where you installed Slime:

```
patch path/to/slime/swank.lisp < swank.lisp-patch
```

The change to ```swank.lisp``` implements the forwarding of Swank protocol
messages from worker machines through the master's Swank server back to your
Slime client.  It's needed to debug problems on worker machines using your
Slime connection to the master.
