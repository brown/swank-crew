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

Swank Crew has been tested with CLISP, CCL, ECL, and SBCL.

## The Swank Crew API

#### connect-workers host/port-alist master-host-name master-swank-port

```
Makes Swank connections to all the workers in HOST/PORT-ALIST and returns a
WORKER-POOL containing them.  HOST/PORT-ALIST is a list of (host-name . port)
pairs.  MASTER-HOST-NAME and MASTER-SWANK-PORT are a host name and Swank port
that workers can use to return results to the master.
```

#### disconnect-workers worker-pool

```
Closes the Swank connections of all connected workers in WORKER-POOL.
```

#### eval-form-all-workers worker-pool form &key result-done (replay-required t)

```
Evaluates FORM on all workers in WORKER-POOL.  When RESULT-DONE is non-NIL, it
must be a function of two arguments.  In this case RESULT-DONE is called as
each worker returns a result with two arguments, a non-negative integer
representing the order in which the work was dispatched and the worker's
result.  If REPLAY-REQUIRED is true, which is the default, FORM will be
remembered and evaluated again for side effects on any new worker that joins
POOL.
```

#### eval-form-repeatedly worker-pool result-count form &key (worker-count (worker-count worker-pool))

```
Evaluates FORM, which must return a function of no arguments, on WORKER-COUNT
workers in WORKER-POOL, then arranges for the workers to repeatedly call the
function to create RESULT-COUNT results, which are returned in a list.
WORKER-COUNT defaults to the number of workers in WORKER-POOL.
```

#### eval-repeatedly-async-state worker-pool form initial-state update-state &key (worker-count (worker-count worker-pool))

```
Evaluates FORM, which must return a function of one argument, on WORKER-COUNT
workers in WORKER-POOL, then arranges for the workers to repeatedly call the
work function and send its results back to the master.  The work function is
passed a state argument, initially set to INITIAL-STATE, that the master can
update asynchronously as it receives new results.

On the master, the work state is initialized to INITIAL-STATE and UPDATE-STATE
is called repeatedly to process results received from the workers.
UPDATE-STATE is called with two arguments, the current work state and a list
containing all unprocessed work results.  UPDATE-STATE should return three
values: the new work state, a boolean indicating whether the computation should
end, and a boolean indicating whether the latest work state should be
distributed to workers.  When UPDATE-STATE's second return value is true,
EVAL-REPEATEDLY-ASYNC-STATE tells the workers to stop and returns the latest
work state.
```

#### parallel-mapcar worker-pool make-work list &optional result-done

```
Traverses LIST, calling MAKE-WORK on each element to create a form that is then
passed to a remote worker in WORKER-POOL for evaluation.  Results of evaluating
each form are collected into a list, which is returned when every remote worker
is done.  If RESULT-DONE is provided, then it must be a function of two
arguments.  In this case RESULT-DONE is called on the master as each worker
returns a result.  The arguments to RESULT-DONE are the position of the work in
LIST and the worker's result.
```

#### parallel-reduce worker-pool make-work list initial-value reducer

```
Traverses LIST, calling MAKE-WORK on each element to create a form that is
then passed to a remote worker in WORKER-POOL for evaluation.  As results are
returned, REDUCER, a binary function, is used to combine successive results in
the manner of REDUCE.  INITIAL-VALUE is used as the starting value for the
reduction computation.  The form

  (parallel-reduce worker-pool make-work list initial-value reducer)

is equivalent to

  (reduce reducer
          (mapcar (lambda (x) (eval (funcall make-work x))) list)
          :initial-value initial-value)
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
