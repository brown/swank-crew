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

;;;; Swank Crew code that runs on worker machines.

(in-package #:swank-crew)

(defvar *last-form-evaled* nil "The last form evaluated by the worker.")

(defvar *last-random-state* nil
  "The value of *RANDOM-STATE* right before the worker started evaluating
*LAST-FORM-EVALED*.")

(defvar *last-repeated-eval-work-function* nil
  "Thunk created by the current invocation of REPEATEDLY-EVALUATE to produce
results for an EVAL-FORM-REPEATEDLY request on the master.  This variable is
useful for debugging.")

(defun clear-debugging-info ()
  "Sets all debugging global variables to NIL."
  (setf *last-form-evaled* nil
        *last-repeated-eval-work-function* nil
        *last-random-state* nil))

(defun debugging-form (form)
  "Returns an expression that when evaluated returns the result of evaluating
FORM.  In addition, the returned expression arranges to update the values of
*LAST-FORM-EVALED* and *LAST-RANDOM-STATE* for ease of debugging."
  ;; Remember FORM and the initial state of the random number generator while FORM is being
  ;; evaluated.  If the evaluation fails, having the values handy makes reproducing the bug easier.
  `(progn (setf *last-form-evaled* ',form
                *last-random-state* (make-random-state nil))
          (prog1 ,form
            ;; When form evaluates normally, clear the debugging information to save space.
            (setf *last-form-evaled* nil
                  *last-random-state* nil))))

(defvar *replay-forms-counts-lock* (make-lock "evaluated form count")
  "Lock protecting access to *REPLAY-FORMS-COUNTS*.")

(defvar *replay-forms-counts* (make-hash-table)
  "Mapping from worker pool IDs to the number of replay forms we have evaluated
on this client for that pool.")

(defun fetch-and-evaluate (master-host-name master-swank-port worker-pool-id local-count)
  "Fetches from the master and then evaluates all forms required to catch up
with other workers in the pool identified by WORKER-POOL-ID on the master.  All
replay forms after the first LOCAL-COUNT forms are fetched by making a Swank
connection to host MASTER-HOST-NAME on port MASTER-SWANK-PORT."
  (let ((forms
          (handler-case
              (with-slime-connection (connection master-host-name master-swank-port)
                (slime-eval `(unevaluated-replay-forms ,worker-pool-id ,local-count) connection))
            (slime-network-error ()
              '()))))
    (dolist (form forms)
      (eval (debugging-form form))
      (incf (gethash worker-pool-id *replay-forms-counts* 0)))))

(defun catch-up-if-necessary (master-host-name master-swank-port worker-pool-id pool-count)
  "Ensures that the current client is up to date, that it has evaluated all
POOL-COUNT replay forms associated with the pool identified by WORKER-POOL-ID.
If it is necessary to evaluate forms in order to catch up, they are fetched by
making a Swank connection to host MASTER-HOST-NAME on port MASTER-SWANK-PORT."
  (let ((up-to-date nil))
    (with-lock-held (*replay-forms-counts-lock*)
      (let ((count (gethash worker-pool-id *replay-forms-counts* 0)))
        (when (< count pool-count)
          (fetch-and-evaluate master-host-name master-swank-port worker-pool-id count))
        (when (= (gethash worker-pool-id *replay-forms-counts* 0) pool-count)
          (setf up-to-date t))))
    (unless up-to-date (error "worker failed to catch up"))))

(defun evaluate-form (form master-host-name master-swank-port worker-pool-id pool-count
                      replay-required)
  "Evaluates FORM, but first ensures that this worker has evaluated all
POOL-COUNT replay forms associated with the worker pool identified by
WORKER-POOL-ID on the master.  When catching up is required, fetches forms by
making a Swank connection to host MASTER-HOST-NAME on port MASTER-SWANK-PORT.
REPLAY-REQUIRED indicates whether FORM may need to be replayed in order to
bring a worker up to date."
  (catch-up-if-necessary master-host-name master-swank-port worker-pool-id pool-count)
  (let ((result (eval (debugging-form form))))
    (when replay-required
      (with-lock-held (*replay-forms-counts-lock*)
        (incf (gethash worker-pool-id *replay-forms-counts* 0))))
    result))

(defun send-many-results (send-result master-host-name master-swank-port)
  "Creates a Slime connection to host MASTER-HOST-NAME on port MASTER-SWANK-PORT,
then repeatedly calls SEND-RESULT with the new connection as argument.  Returns
when SEND-RESULT returns NIL."
  (handler-case
      (with-slime-connection (connection master-host-name master-swank-port)
        (loop while (funcall send-result connection)))
    (slime-network-error ()
      nil)))

(defun repeatedly-evaluate (form id master-host-name master-swank-port)
  "Evaluates FORM, which must return a function of no arguments, then calls
that function repeatedly to produce results.  Each result is sent to host
MASTER-HOST-NAME by making a Swank connection on port MASTER-SWANK-PORT and
remotely evaluating an expression that records the result.  ID is used on the
master machine to correctly record the result."
  (setf *last-form-evaled* form)
  (let ((work-function (eval form)))
    (setf *last-repeated-eval-work-function* work-function)
    (flet ((send-result (connection)
             (setf *last-random-state* (make-random-state nil))
             (slime-eval `(record-repeated-result ,id ',(funcall work-function)) connection)))
      (make-thread (lambda ()
                     (send-many-results #'send-result master-host-name master-swank-port)
                     (clear-debugging-info))
                   :name "repeatedly evaluate")
      ;; We must return a value that can be serialized.
      t)))

(defun async-evaluate (form initial-state id master-host-name master-swank-port)
  "Evaluates FORM, which must return a work function of one argument, then
calls that function repeatedly to produce results, each time passing it the
current computation state.  At first this state is INITIAL-STATE, but the
master may update the state asynchronously.  Each work result is sent to host
MASTER-HOST-NAME by making a Swank connection to port MASTER-SWANK-PORT and
remotely evaluating an expression that records the result.  ID is used on the
master machine to process results and on the worker to update the state."
  (let ((state initial-state)
        (state-counter 0))
    (setf *last-form-evaled* form)
    (let ((work-function (eval form)))
      (setf *last-repeated-eval-work-function* work-function)
      (flet ((send-result (connection)
               (setf *last-random-state* (make-random-state nil))
               (let ((result (funcall work-function state)))
                 (destructuring-bind (continue counter new-state)
                     (slime-eval `(record-async-result ,id ',result ,state-counter) connection)
                   (when (and continue (/= counter state-counter))
                     (setf state-counter counter
                           state new-state))
                   continue))))
        (make-thread (lambda ()
                       (send-many-results #'send-result master-host-name master-swank-port)
                       (clear-debugging-info))
                     :name "async evaluate")
        ;; We must return a value that can be serialized.
        t))))
