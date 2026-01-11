;;;; Copyright 2011 Google Inc.  All Rights Reserved

;;;; Redistribution and use in source and binary forms, with or without
;;;; modification, are permitted provided that the following conditions are
;;;; met:

;;;;     * Redistributions of source code must retain the above copyright
;;;; notice, this list of conditions and the following disclaimer.
;;;;     * Redistributions in binary form must reproduce the above
;;;; copyright notice, this list of conditions and the following disclaimer
;;;; in the documentation and/or other materials provided with the
;;;; distribution.
;;;;     * Neither the name of Google Inc. nor the names of its
;;;; contributors may be used to endorse or promote products derived from
;;;; this software without specific prior written permission.

;;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;; A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;; OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;; SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;;; LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;;;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;;;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;;;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;;;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;;; Author: Robert Brown <robert.brown@gmail.com>

;;;; Swank Crew code that runs on the master machine.

(in-package #:swank-crew)

(deftype port () "A non-privileged TCP/IP port number." '(integer 1024 65535))

(defclass connect-info ()
  ((host-name :accessor host-name
              :type string
              :initarg :host-name
              :initform (missing-argument)
              :documentation "Host the worker is running on.")
   (port :accessor port
         :type port
         :initarg :port
         :initform (missing-argument)
         :documentation "Port on which the worker's Swank server is listening for connections."))
  (:documentation "Information needed when connecting to a worker's Swank server."))

(defclass worker ()
  ((connect-info :reader connect-info
                 :type connect-info
                 :initarg :connect-info
                 :initform (missing-argument)
                 :documentation "Information used when connecting to this worker.")
   (lock :reader lock
         :initform (make-lock "worker")
         :documentation "Lock protecting SET-WORKER and CONNECTION.")
   (set-worker :accessor set-worker
               :type function
               :initform #'identity
               :documentation "Function called to record which worker is evaluating a form.")
   (connection :accessor connection
               :type (or null swank-connection)
               :initform nil
               :documentation "When non-NIL, an open Swank connection to the worker."))
  (:documentation "A remote Lisp running a Swank server."))

(defclass worker-pool ()
  ((id :reader id
       :type symbol
       :initarg :id
       :initform (missing-argument)
       :documentation "The worker pool's ID.")
   (master-host-name :reader master-host-name
                     :type string
                     :initarg :master-host-name
                     :initform (missing-argument)
                     :documentation
"Host name of the master.  Used by workers to return results to the master.")
   (master-swank-port :reader master-swank-port
                      :type port
                      :initarg :master-swank-port
                      :initform (missing-argument)
                      :documentation
"Port on the master on which a Swank server is listening.  Used by workers to
return results to the master.")
   (workers :reader workers
            :writer (setf %workers)     ; only used when a worker pool is constructed
            :type vector
            :initform #()
            :documentation "Vector containing all workers in the worker pool.")
   (lock :reader lock
         :initform (make-lock "worker pool")
         :documentation "Lock protecting IDLE-WORKERS, WORKER-AVAILABLE, and DISCONNECTING.")
   (idle-workers :accessor idle-workers
                 :type list
                 :initform '()
                 :documentation "List of currently idle workers.")
   (worker-available :reader worker-available
                     :initform (make-condition-variable)
                     :documentation "Condition signaled when a worker becomes idle.")
   (disconnecting :accessor disconnecting
                  :initform nil
                  :documentation
"Set non-NIL when the worker pool is being torn down to tell the reconnector
thread it should exit.")
   (replay-forms-lock :reader replay-forms-lock
                      :initform (make-lock "replay forms lock")
                      :documentation "Lock that protects REPLAY-FORMS.")
   (replay-forms :accessor replay-forms
                 :type list
                 :initform '()
                 :documentation
"List containing all forms passed to EVAL-FORM-ALL-WORKERS that need to be
replayed on new workers when they join the pool."))
  (:documentation "A pool of Swank workers to which Lisp forms can be sent for evaluation."))

(defun worker-counts (worker-pool)
  "Returns the number of idle, busy, and disconnected workers in WORKER-POOL.
This function executes without locking WORKER-POOL, so it may return
inconsistent information."
  ;; We copy the idle workers list without holding a lock on WORKER-POOL.  Other threads may be
  ;; simultaneously popping workers off the head of the list, so we may get stale data.
  (let ((idlers (copy-seq (idle-workers worker-pool)))
        (idle-hash (make-hash-table :test 'eq)))
    (dolist (idle-worker idlers)
      (setf (gethash idle-worker idle-hash) t))
    (let ((idle 0)
          (busy 0)
          (disconnected 0))
      (loop for worker across (workers worker-pool) do
        ;; We call (CONNECTION WORKER) without holding the worker's lock, so we may get stale data
        ;; here as well.
        (cond ((null (connection worker)) (incf disconnected))
              ((gethash worker idle-hash) (incf idle))
              (t (incf busy))))
      (values idle busy disconnected))))

(defun worker-count (worker-pool)
  "Returns the total number of workers in WORKER-POOL."
  (length (workers worker-pool)))

(defmethod print-object ((worker-pool worker-pool) stream)
  "Prints WORKER-POOL to STREAM.  This function runs without locking
WORKER-POOL, so it may output inconsistent information."
  (print-unreadable-object (worker-pool stream :type t :identity t)
    (multiple-value-bind (idle busy disconnected)
        (worker-counts worker-pool)
      (format stream "id: ~S workers: ~D idle: ~D busy: ~D disconnected: ~D"
              (id worker-pool) (worker-count worker-pool) idle busy disconnected))))

(defvar *worker-pools-lock* (make-lock "worker pools lock")
  "Lock protecting access to *WORKER-POOLS*.")

(defvar *worker-pools* (make-hash-table) "Mapping from worker pool IDs to active worker pools.")

(defmethod initialize-instance :after ((worker-pool worker-pool) &key)
  (with-lock-held (*worker-pools-lock*)
    (setf (gethash (id worker-pool) *worker-pools*) worker-pool)))

(defun find-worker-pool (worker-pool-id)
  "Returns the worker pool identified by WORKER-POOL-ID."
  (with-lock-held (*worker-pools-lock*)
    (gethash worker-pool-id *worker-pools*)))

(defun make-worker-pool (master-host-name master-swank-port connect-infos connect-worker)
  (let* ((worker-pool (make-instance 'worker-pool
                                     :id (gentemp (string-upcase master-host-name) "KEYWORD")
                                     :master-host-name master-host-name
                                     :master-swank-port master-swank-port))
         (workers
           (loop for connect-info in connect-infos
                 for worker = (make-instance 'worker :connect-info connect-info)
                 do (let ((worker worker))
                      (setf (connection worker)
                            (funcall connect-worker
                                     connect-info
                                     (lambda () (handle-connection-closed worker worker-pool)))))
                 collect worker)))
    (setf (%workers worker-pool) (coerce workers 'vector)
          (idle-workers worker-pool) workers)
    (make-thread (lambda () (reconnect-workers worker-pool)) :name "reconnector")
    worker-pool))

(defgeneric connect-worker (connect-info close-handler)
  (:documentation
   "Creates a connection to a worker's Swank server using information in
CONNECT-INFO.  Passes the thunk CLOSE-HANDLER to SWANK-CLIENT:SLIME-CONNECT, so
that it is invoked when the connection closes."))

(defmethod connect-worker ((connect-info connect-info) close-handler)
  (slime-connect (host-name connect-info) (port connect-info) close-handler))

(defun connect-workers (host/port-alist master-host-name master-swank-port)
  "Makes Swank connections to all the workers in HOST/PORT-ALIST and returns a
WORKER-POOL containing them.  HOST/PORT-ALIST is a list of (host-name . port)
pairs.  MASTER-HOST-NAME and MASTER-SWANK-PORT are a host name and Swank port
that workers can use to return results to the master."
  (let ((connect-infos
          (loop for (host-name . port) in host/port-alist
                collect (make-instance 'connect-info :host-name host-name :port port))))
    (make-worker-pool master-host-name master-swank-port connect-infos #'connect-worker)))

(defun disconnect-workers (worker-pool)
  "Closes the Swank connections of all connected workers in WORKER-POOL."
  (with-lock-held ((lock worker-pool))
    (when (disconnecting worker-pool)
      (return-from disconnect-workers))
    ;; Signal that the worker pool is being torn down and make sure there are no idle workers
    ;; available.  After the pool is marked as disconnecting, no workers will transition to idle.
    (setf (disconnecting worker-pool) t)
    (setf (idle-workers worker-pool) '()))
  (flet ((disconnect (worker)
           (with-lock-held ((lock worker))
             (when (connection worker)
               (slime-close (connection worker))))))
    ;; Disconnect all workers.
    (loop for worker across (workers worker-pool) do (disconnect worker)))
  (values))

(defgeneric reconnect-worker (connect-info close-handler)
  (:documentation
   "Reconnects to a Swank server using information in CONNECT-INFO.  Passes the
thunk CLOSE-HANDLER to SWANK-CLIENT:SLIME-CONNECT, so that it is invoked when
the connection closes."))

(defmethod reconnect-worker ((connect-info connect-info) close-handler)
  (connect-worker connect-info close-handler))

(defconstant +worker-reconnect-interval+ 10 "Seconds between attempts to reconnect workers.")

(defun reconnect-workers (worker-pool)
  "Reconnects disconnected workers in WORKER-POOL."
  (loop
    (sleep +worker-reconnect-interval+)
    (with-lock-held ((lock worker-pool))
      (when (disconnecting worker-pool)
        (return-from reconnect-workers)))
    (loop for worker across (workers worker-pool) do
      (let ((worker worker))
        (when (with-lock-held ((lock worker))
                (unless (connection worker)
                  (let ((close-handler (lambda () (handle-connection-closed worker worker-pool))))
                    (setf (connection worker)
                          (reconnect-worker (connect-info worker) close-handler)))))
          (with-lock-held ((lock worker-pool))
            (when (member worker (idle-workers worker-pool))
              ;; We reconnected an idle worker, so notify the pool that a worker is available.
              (condition-notify (worker-available worker-pool)))))))))

(defun allocate-worker (worker-pool &key worker-to-avoid)
  "Allocates and returns an idle worker from WORKER-POOL that is connected.  If
WORKER-POOL is being shut down, then NIL is returned."
  (with-lock-held ((lock worker-pool))
    (loop
      (when (disconnecting worker-pool) (return nil))
      ;; Find a connected idle worker.
      (let ((idle-worker (find-if (lambda (worker)
                                    (unless (eql worker worker-to-avoid)
                                      (with-lock-held ((lock worker))
                                        (connection worker))))
                                  (idle-workers worker-pool))))
        (when idle-worker
          (setf (idle-workers worker-pool) (remove idle-worker (idle-workers worker-pool)))
          (return idle-worker)))
      (condition-wait (worker-available worker-pool) (lock worker-pool)))))

(defun free-worker (worker worker-pool)
  "Changes the state of WORKER to idle, so that it's available for allocation."
  (with-lock-held ((lock worker-pool))
    (unless (disconnecting worker-pool)
      (push worker (idle-workers worker-pool))
      (when (connection worker)
        ;; The free worker is connected, so notify the pool that a worker is available.
        (condition-notify (worker-available worker-pool))))))

(defun allocate-worker-and-evaluate (worker-pool form set-worker worker-done)
  "Allocates a connected worker from WORKER-POOL and sends it FORM to evaluate.
Returns the worker that was successfully allocated, or NIL if WORKER-POOL is
shutting down.  SET-WORKER is a function that is called to tell the WORKER-DONE
continuation what worker is evaluating FORM."
  (let ((worker nil)
        (disconnected-idle-workers '()))
    (loop do
      (setf worker (allocate-worker worker-pool))
      (unless worker (return-from allocate-worker-and-evaluate nil))
      (with-lock-held ((lock worker))
        ;; Has the connected idle worker we allocated just disconnected?
        (let ((connection (connection worker)))
          (if connection
              (progn
                (setf (set-worker worker) set-worker)
                (funcall set-worker worker)
                ;; Ignore network errors.  If there is a network problem, socket keep alives will
                ;; eventually discover that the connection is dead and HANDLE-CONNECTION-CLOSED
                ;; will migrate the work to another worker.
                (handler-case (slime-eval-async form connection worker-done)
                  (slime-network-error ()))
                (loop-finish))
              ;; The worker is disconnected, so remember it and look for another one.
              (push worker disconnected-idle-workers)))))
    ;; Place any disconnected workers we found back on the idle workers list.
    (dolist (w disconnected-idle-workers) (free-worker w worker-pool))
    worker))

(defun handle-connection-closed (disconnected-worker worker-pool)
  "Called when the connection to DISCONNECTED-WORKER, a member of WORKER-POOL,
is closed because of a call to SLIME-CLOSE, the death of the worker, or because
of a communications error.  Moves all uncompleted work intended for
DISCONNECTED-WORKER to another idle connected worker in WORKER-POOL."
  (with-lock-held ((lock disconnected-worker))
    (let ((old-connection (connection disconnected-worker))
          (disconnected-idle-workers '()))
      (when (slime-pending-evals-p old-connection)
        (loop do
          (let ((worker (allocate-worker worker-pool :worker-to-avoid disconnected-worker)))
            (unless worker (return-from handle-connection-closed))
            (with-lock-held ((lock worker))
              ;; Has the connected idle worker we allocated just disconnected?
              (let ((connection (connection worker)))
                (if connection
                    (let ((old-set-worker (set-worker disconnected-worker)))
                      ;; Migrate all pending work from DISCONNECTED-WORKER to WORKER.
                      (setf (set-worker worker) old-set-worker)
                      (funcall old-set-worker worker)
                      ;; Ignore Slime network errors.  If there is a network problem, socket keep
                      ;; alives will eventually discover that the connection is dead and
                      ;; HANDLE-CONNECTION-CLOSED will migrate the pending work again.
                      (handler-case (slime-migrate-evals old-connection connection)
                        (slime-network-error ()))
                      (loop-finish))
                    ;; The worker is disconnected, so remember it and look for another one.
                    (push worker disconnected-idle-workers))))))
        ;; Place any disconnected workers we found back on the idle workers list.
        (dolist (w disconnected-idle-workers) (free-worker w worker-pool))))
    ;; Allow the reconnector to see that DISCONNECTED-WORKER is dead.
    (setf (connection disconnected-worker) nil)))

(defun no-workers-p (worker-pool)
  "Returns T if WORKER-POOL is NIL or contains no workers."
  (or (null worker-pool) (zerop (worker-count worker-pool))))

(defun eval-on-master (make-work list result-done)
  "Iterates over the members of LIST calling MAKE-WORK on each one.  If
RESULT-DONE is not NIL, it must be a function of two arguments.  In this case,
after each application of MAKE-WORK to a LIST member, RESULT-DONE is called with
the member's position in LIST and MAKE-WORK's result."
  (loop for position from 0
        for element in list
        for result = (eval (funcall make-work element))
        collect result
        do (when result-done (funcall result-done position result))))

(defun add-evaluated-form (worker-pool form)
  "Adds FORM to the set of forms that need to be evaluated on a new worker when
it joins WORKER-POOL."
  (with-lock-held ((replay-forms-lock worker-pool))
    (push form (replay-forms worker-pool))))

(defun unevaluated-replay-forms (worker-pool-id evaluated-count)
  "For a worker that has executed EVALUATED-COUNT of the replay forms associated
with the worker-pool identified by WORKER-POOL-ID, returns a list of the forms
the worker needs to evaluate in order to be completely up to date."
  (let ((worker-pool (find-worker-pool worker-pool-id)))
    (when worker-pool
      (with-lock-held ((replay-forms-lock worker-pool))
        (nthcdr evaluated-count (reverse (replay-forms worker-pool)))))))

(defun ensure-caught-up-then-evaluate (form worker-pool replay-required)
  "Returns a form that when evaluated on a worker in WORKER-POOL ensures that
the worker is caught up then evaluates FORM and returns its result.
REPLAY-REQUIRED indicates whether new workers must evaluate FORM before being
considered to be caught up."
  (let ((forms-count (with-lock-held ((replay-forms-lock worker-pool))
                       (length (replay-forms worker-pool))))
        (master-host-name (master-host-name worker-pool))
        (master-swank-port (master-swank-port worker-pool))
        (worker-pool-id (id worker-pool)))
    `(evaluate-form ',form ,master-host-name ,master-swank-port ,worker-pool-id ,forms-count
                    ,replay-required)))

(defun dispatch-work (worker-pool make-work list result-done retain-workers replay-required)
  "Traverses LIST, calling MAKE-WORK on each element to create a form that is
then passed to a remote worker in WORKER-POOL for evaluation.  When
RETAIN-WORKERS is true, each form is evaluated on a unique worker.  Otherwise,
workers are reused and may process multiple forms.  In either case, the results
of evaluating each form are collected into a list, which is returned when every
remote worker is done.  If RESULT-DONE is not NIL, then it must be a function of
two arguments.  In this case RESULT-DONE is called on the master as each worker
returns a result.  The arguments to RESULT-DONE are an integer counter,
indicating the work form's position in LIST, and the result of evaluating the
form.  REPLAY-REQUIRED indicates whether new workers will have to perform the
work generated by MAKE-WORK before being considered to be caught up."
  (if (no-workers-p worker-pool)
      (eval-on-master make-work list result-done)
      (let* ((work-count (length list))
             (results (make-list work-count))
             (done-lock (make-lock "dispatch work"))
             (done-condition (make-condition-variable)))
        (loop for element in list
              for result-cons = results then (cdr result-cons)
              for position from 0
              do (let ((result-cons result-cons)
                       (worker nil)
                       (position position))
                   (flet ((set-worker (w) (setf worker w))
                          (worker-done (result)
                            (setf (car result-cons) result)
                            ;; Unless we need each worker to evaluate exactly one form, free the
                            ;; worker, so it can process other work.
                            (unless retain-workers (free-worker worker worker-pool))
                            (with-lock-held (done-lock)
                              (decf work-count)
                              (when result-done (funcall result-done position result))
                              (when (zerop work-count)
                                (condition-notify done-condition)))))
                     (let ((work (ensure-caught-up-then-evaluate (funcall make-work element)
                                                                 worker-pool
                                                                 replay-required)))
                       (allocate-worker-and-evaluate worker-pool
                                                     work
                                                     #'set-worker
                                                     #'worker-done)))))
        (with-lock-held (done-lock)
          (loop until (zerop work-count)
                do (condition-wait done-condition done-lock)))
        ;; When we need each worker to evaluate exactly one form, we end up having allocated every
        ;; worker in the pool, so we need to free them all.
        (when retain-workers
          (loop for worker across (workers worker-pool) do (free-worker worker worker-pool)))
        results)))

(defun eval-form-all-workers (worker-pool form &key result-done (replay-required t))
  "Evaluates FORM on all workers in WORKER-POOL.  When RESULT-DONE is non-NIL,
it must be a function of two arguments.  In this case RESULT-DONE is called as
each worker returns a result with two arguments, a non-negative integer
representing the order in which the work was dispatched and the worker's result.
If REPLAY-REQUIRED is true, which is the default, FORM will be remembered and
evaluated again for side effects on any new worker that joins POOL."
  (let* ((work-list (make-list (if (no-workers-p worker-pool) 1 (worker-count worker-pool))))
         (make-work (constantly form))
         (results (dispatch-work worker-pool make-work work-list result-done t replay-required)))
    (when (and worker-pool replay-required) (add-evaluated-form worker-pool form))
    results))

(defun parallel-mapcar (worker-pool make-work list &optional result-done)
  "Traverses LIST, calling MAKE-WORK on each element to create a form that is
then passed to a remote worker in WORKER-POOL for evaluation.  Results of
evaluating each form are collected into a list, which is returned when every
remote worker is done.  If RESULT-DONE is provided, then it must be a function
of two arguments.  In this case RESULT-DONE is called on the master as each
worker returns a result.  The arguments to RESULT-DONE are the position of the
work in LIST and the worker's result."
  (dispatch-work worker-pool make-work list result-done nil nil))

(defun parallel-reduce (worker-pool make-work list initial-value reducer)
  "Traverses LIST, calling MAKE-WORK on each element to create a form that is
then passed to a remote worker in WORKER-POOL for evaluation.  As results are
returned, REDUCER, a binary function, is used to combine successive results in
the manner of REDUCE.  INITIAL-VALUE is used as the starting value for the
reduction computation.  The form

  (parallel-reduce worker-pool make-work list initial-value reducer)

is equivalent to

  (reduce reducer
          (mapcar (lambda (x) (eval (funcall make-work x))) list)
          :initial-value initial-value)"
  (if (no-workers-p worker-pool)
      (reduce reducer
              (mapcar (lambda (x) (eval (funcall make-work x))) list)
              :initial-value initial-value)
      (let* ((work-count (length list))
             (unknown-result (cons nil nil))
             (results (make-array (1+ work-count) :initial-element unknown-result))
             (i 0)
             (reduce-result initial-value)
             (done-lock (make-lock "parallel reduce"))
             (done-condition (make-condition-variable)))
        (loop for element in list
              for position from 0
              do (let ((worker nil)
                       (position position))
                   (flet ((set-worker (w) (setf worker w))
                          (worker-done (result)
                            (free-worker worker worker-pool)
                            (with-lock-held (done-lock)
                              (setf (aref results position) result)
                              (loop for next = (aref results i)
                                    while (not (eq next unknown-result))
                                    do (setf reduce-result (funcall reducer reduce-result next))
                                       (setf (aref results i) nil)
                                       (incf i))
                              (decf work-count)
                              (when (zerop work-count)
                                (condition-notify done-condition)))))
                     (let ((work (ensure-caught-up-then-evaluate (funcall make-work element)
                                                                 worker-pool
                                                                 nil)))
                       (allocate-worker-and-evaluate worker-pool
                                                     work
                                                     #'set-worker
                                                     #'worker-done)))))
        (with-lock-held (done-lock)
          (loop until (zerop work-count)
                do (condition-wait done-condition done-lock)))
        reduce-result)))

(defvar *evaluation-id-lock* (make-lock "eval id")
  "Lock protecting access to *EVALUATION-ID*.")

(defvar *evaluation-id* 0 "Counter used to generate a unique ID for EVALUATION instances.")

(defclass evaluation ()
  ((id :reader id
       :type integer
       :initarg :id
       :initform (with-lock-held (*evaluation-id-lock*)
                   (incf *evaluation-id*))
       :documentation "Unique ID for this running evaluation request.")
   (lock :reader lock
         :initform (make-lock "evaluation")
         :documentation "Lock protecting access to DONE, DONE-CONDITION, and other mutable slots.")
   (done :accessor done
         :type boolean
         :initform nil
         :documentation "Is the computation done?")
   (done-condition :reader done-condition
                   :initform (make-condition-variable)
                   :documentation "Condition variable notified when computation is done."))
  (:documentation "Stores the data needed to process incoming evaluation results."))

(defclass repeated-eval (evaluation)
  ((results :reader results
            :type simple-vector
            :initarg :results
            :initform (missing-argument)
            :documentation "Vector holding returned results.")
   (results-position :accessor results-position
                     :type vector-index
                     :initform 0
                     :documentation "Position where the next result will be recorded."))
  (:documentation "Stores the data needed to process an incoming repeated eval result."))

(defvar *evals-lock* (make-lock "evals")
  "Lock protecting access to *EVALS*.")

(defvar *evals* '() "List containing an EVALUATION instance for each running computation.")

(defun add-eval (eval)
  "Adds EVAL to the list of in-progress computations."
  (with-lock-held (*evals-lock*)
    (push eval *evals*)))

(defun remove-eval (eval)
  "Removes EVAL from the list of in-progress computations."
  (with-lock-held (*evals-lock*)
    (setf *evals* (remove eval *evals*))))

(defun find-eval (id)
  "Returns the running EVAL instance identified by ID, or NIL if no
computation with that ID is currently running."
  (with-lock-held (*evals-lock*)
    (find id *evals* :test #'= :key #'id)))

(defun record-repeated-result (id result)
  "Stores RESULT as one of the values produced by the repeated evaluation
identified by ID.  Returns a boolean indicating whether the worker should
continue to call RECORD-REPEATED-RESULT with additional results."
  (let ((repeated-eval (find-eval id)))
    (when repeated-eval
      (let ((done nil))
        (with-lock-held ((lock repeated-eval))
          (let* ((results (results repeated-eval))
                 (length (length results))
                 (position (results-position repeated-eval)))
            (when (< position length)
              (setf (aref results position) result)
              (incf position)
              (setf (results-position repeated-eval) position))
            (when (>= position length)
              (setf done t
                    (done repeated-eval) t)
              (condition-notify (done-condition repeated-eval)))))
        (not done)))))

(defun repeated-work-form (form worker-pool id)
  "Returns a form for evaluation on a client of WORKER-POOL that ensures the
client is caught up and then evaluates FORM for the repeated evaluation request
identified by ID."
  (let ((master-host-name (master-host-name worker-pool))
        (master-swank-port (master-swank-port worker-pool)))
    (ensure-caught-up-then-evaluate
     `(repeatedly-evaluate ',form ,id ,master-host-name ,master-swank-port)
     worker-pool
     nil)))

(defun eval-form-repeatedly (worker-pool result-count form
                             &key (worker-count (when worker-pool (worker-count worker-pool))))
  "Evaluates FORM, which must return a function of no arguments, on WORKER-COUNT
workers in WORKER-POOL, then arranges for the workers to repeatedly call the
function to create RESULT-COUNT results, which are returned in a list.
WORKER-COUNT defaults to the number of workers in WORKER-POOL."
  (if (or (no-workers-p worker-pool) (not (plusp worker-count)))
      (let ((work-function (eval form)))
        (loop repeat result-count collect (funcall work-function)))
      (let* ((results (make-instance 'repeated-eval :results (make-array result-count)))
             (results-lock (lock results))
             (retained-workers '()))
        (add-eval results)
        (loop repeat worker-count
              until (with-lock-held (results-lock)
                      (done results))
              do (let ((worker nil))
                   (flet ((set-worker (w) (setf worker w))
                          (worker-done (result)
                            (declare (ignore result))
                            ;; Workers that finish before all results are available are retained,
                            ;; while those that finish later are immediately released.
                            (with-lock-held (results-lock)
                              (if (not (done results))
                                  (push worker retained-workers)
                                  (free-worker worker worker-pool)))))
                     (let ((work (repeated-work-form form worker-pool (id results))))
                       (allocate-worker-and-evaluate worker-pool
                                                     work
                                                     #'set-worker
                                                     #'worker-done)))))
        (with-lock-held (results-lock)
          (loop until (done results)
                do (condition-wait (done-condition results) results-lock)))
        ;; TODO(brown): Perhaps UNWIND-PROTECT should be used to ensure the remove happens.
        (remove-eval results)
        ;; We can manipulate RETAINED-WORKERS without a lock because all results are available,
        ;; so no WORKER-DONE function will modify the list.
        (dolist (w retained-workers) (free-worker w worker-pool))
        (coerce (results results) 'list))))

(defclass async-eval (evaluation)
  ((results :accessor results
            :type list
            :initform '()
            :documentation "List holding returned, but unprocessed, results.")
   (results-available :reader results-available
                      :initform (make-condition-variable)
                      :documentation "Condition notified when new results are available.")
   (state :accessor state
          :initarg :state
          :initform (missing-argument)
          :documentation "State of the asynchronous computation, updated from results.")
   (state-counter :accessor state-counter
                  :type (integer 0)
                  :initform 0
                  :documentation "Counter incremented each time STATE is updated."))
  (:documentation "Data needed to process incoming asynchronous evaluation results."))

(defun async-results-loop (async-eval update-state)
  "Handles incoming results for ASYNC-EVAL by calling UPDATE-STATE whenever
ASYNC-EVAL holds unprocessed results.  UPDATE-STATE is called with two
arguments, the work state and a list of the unprocessed results."
  (let ((lock (lock async-eval))
        (state nil)
        (results nil))
    (loop
      (with-lock-held (lock)
        (loop until (results async-eval)
              do (condition-wait (results-available async-eval) lock))
        (setf state (state async-eval)
              results (results async-eval)
              (results async-eval) '()))
      (multiple-value-bind (new-state done send-state)
          (funcall update-state state results)
        (with-lock-held (lock)
          (setf (state async-eval) new-state)
          (when (and send-state (not done))
            (incf (state-counter async-eval))))
        (when done
          (with-lock-held (lock)
            (setf (done async-eval) t)
            (condition-notify (done-condition async-eval)))
          (return-from async-results-loop))))))

(defun record-async-result (id result worker-state-counter)
  "Stores RESULT as one of the values produced by the async evaluation
identified by ID.  Returns a boolean indicating whether the worker should
continue to call ASYNC-RESULT with additional results."
  (let ((done t)
        (state-counter 0)
        (state nil)
        (async-eval (find-eval id)))
    (when async-eval
      (with-lock-held ((lock async-eval))
        (push result (results async-eval))
        (setf state-counter (state-counter async-eval)
              done (done async-eval))
        (when (/= worker-state-counter state-counter)
          (setf state (state async-eval)))
        (condition-notify (results-available async-eval))))
    (list (not done) state-counter state)))

(defun async-work-form (form initial-state worker-pool id)
  "Returns a form for evaluation on a client of WORKER-POOL that ensures the
client is caught up and then evaluates FORM for the async evaluation request
identified by ID."
  (let ((master-host-name (master-host-name worker-pool))
        (master-swank-port (master-swank-port worker-pool)))
    (ensure-caught-up-then-evaluate
     `(async-evaluate ',form ',initial-state ,id ,master-host-name ,master-swank-port)
     worker-pool
     nil)))

(defun eval-repeatedly-async-state (worker-pool form initial-state update-state
                                    &key (worker-count
                                          (when worker-pool (worker-count worker-pool))))
  "Evaluates FORM, which must return a function of one argument, on WORKER-COUNT
workers in WORKER-POOL, then arranges for the workers to repeatedly call the
work function and send its results back to the master.  The work function is
passed a state argument, initially set to INITIAL-STATE, that the master can
update asynchronously as it receives new results.

On the master, the work state is initialized to INITIAL-STATE and UPDATE-STATE
is called repeatedly to process results received from the workers.  UPDATE-STATE
is called with two arguments, the current work state and a list containing all
unprocessed work results.  UPDATE-STATE should return three values: the new work
state, a boolean indicating whether the computation should end, and a boolean
indicating whether the latest work state should be distributed to workers.  When
UPDATE-STATE's second return value is true, EVAL-REPEATEDLY-ASYNC-STATE tells
the workers to stop and returns the latest work state."
  (if (or (no-workers-p worker-pool) (not (plusp worker-count)))
      (let ((work-function (eval form))
            (state initial-state))
        (loop (multiple-value-bind (new-state done send-state)
                  (funcall update-state state (list (funcall work-function state)))
                (when done (return new-state))
                (when send-state (setf state new-state)))))
      (let* ((results (make-instance 'async-eval :state initial-state))
             (results-lock (lock results))
             (retained-workers '()))
        (add-eval results)
        (make-thread (lambda () (async-results-loop results update-state))
                     :name "async results loop")
        (loop repeat worker-count
              until (with-lock-held (results-lock)
                      (done results))
              do (let ((worker nil))
                   (flet ((set-worker (w) (setf worker w))
                          (worker-done (result)
                            (declare (ignore result))
                            ;; Workers that finish before all results are available are retained,
                            ;; while those that finish later are immediately released.
                            (with-lock-held (results-lock)
                              (if (not (done results))
                                  (push worker retained-workers)
                                  (free-worker worker worker-pool)))))
                     (let ((work (async-work-form form initial-state worker-pool (id results))))
                       (allocate-worker-and-evaluate worker-pool
                                                     work
                                                     #'set-worker
                                                     #'worker-done)))))
        (with-lock-held (results-lock)
          (loop until (done results)
                do (condition-wait (done-condition results) results-lock)))
        ;; TODO(brown): Perhaps UNWIND-PROTECT should be used to ensure the remove happens.
        (remove-eval results)
        ;; We can manipulate RETAINED-WORKERS without a lock because all results are available, so
        ;; no WORKER-DONE function will modify the list.
        (dolist (w retained-workers) (free-worker w worker-pool))
        (state results))))
