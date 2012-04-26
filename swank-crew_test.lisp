;;;; Copyright 2012 Google Inc.  All Rights Reserved

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

;;;; Author: brown@google.com (Robert Brown)

;;;; Test the code in the SWANK-CREW package.

(in-package #:common-lisp-user)

(defpackage #:swank-crew-test
  (:documentation "Test code in the SWANK-CREW package.")
  (:use #:common-lisp
        #:com.google.base
        #:hu.dwim.stefil
        #:swank-crew)
  (:export #:test-swank-crew))

(in-package #:swank-crew-test)
(declaim #.*optimize-default*)

(defsuite (test-swank-crew :in root-suite) ()
  (run-child-tests))

(in-suite test-swank-crew)

(defun test-eval-form-all-workers (pool)
  (let* ((worker-count (if (null pool) 1 (worker-count pool)))
         (work '(cons 1 2))
         (expected-result (make-list worker-count :initial-element '(1 . 2)))
         (count 0)
         (count-lock (bordeaux-threads:make-lock "count")))
    (flet ((result-done (position element)
             (bordeaux-threads:with-lock-held (count-lock)
               (incf count)
               (is (equal (nth position expected-result) element)))))
      (is (equal (eval-form-all-workers pool work :replay-required nil) expected-result))
      (is (equal (eval-form-all-workers pool work :result-done #'result-done :replay-required nil)
                 expected-result))
      (is (= count worker-count)))))

(defun test-eval-form-repeatedly (pool)
  (let ((worker-count (if (null pool) 1 (worker-count pool))))
    (is (equal (eval-form-repeatedly pool 10 '(constantly (cons 1 2)))
               (make-list 10 :initial-element (cons 1 2))))
    (is (equal (eval-form-repeatedly pool 20 '(constantly (cons 3 4))
                                     :worker-count (floor (/ worker-count 2)))
               (make-list 20 :initial-element (cons 3 4))))
    (is (equal (eval-form-repeatedly pool 30 '(constantly (cons 5 6)) :worker-count 0)
               (make-list 30 :initial-element (cons 5 6))))))

(defun test-parallel-mapcar (pool)
  (let ((input '(100 200 300))
        (expected-result '((100 . 1) (200 . 1) (300 . 1)))
        (count 0))
    (flet ((result-done (position element)
             (incf count)
             (is (equal (nth position expected-result) element))))
      (is (equal (parallel-mapcar pool (lambda (x) `(cons ,x 1)) input) expected-result))
      (is (equal (parallel-mapcar pool (lambda (x) `(cons ,x 1)) input #'result-done)
                 expected-result))
      (is (= count (length expected-result))))))

(defun test-parallel-reduce (pool)
  (is (equal (parallel-reduce pool
                              (lambda (x) `(list ,x 1))
                              '(100 200 300)
                              '(a b c)
                              #'append)
             '(a b c 100 1 200 1 300 1))))

(defun test-eval-repeatedly-async-state (pool)
  (let ((expected-state 10)
        (update-count 0)
        (work-form '(lambda (state)
                     ;; Return results slowly so we don't create huge result lists.
                     (sleep 0.1)
                     (* state state))))
    (flet ((update-state (state results)
             (is (= state expected-state))
             (is (not (null results)))
             (dolist (result results)
               (is (or (= result (expt state 2))
                       (= result (expt (1- state) 2))
                       (= result (expt (- state 2) 2)))))
             ;; Allow time for several results to accumulate.
             (sleep 0.5)
             (values (incf expected-state) (> (incf update-count) 3) t)))
      (eval-repeatedly-async-state pool work-form 10 #'update-state :worker-count 0)
      (setf expected-state 10
            update-count 0)
      (eval-repeatedly-async-state pool work-form 10 #'update-state))))

;;; Tests that use a NIL worker pool.

(deftest test-eval-form-all-workers-nil-pool ()
  (test-eval-form-all-workers nil))

(deftest test-eval-form-repeatedly-nil-pool ()
  (test-eval-form-repeatedly nil))

(deftest test-parallel-mapcar-nil-pool ()
  (test-parallel-mapcar nil))

(deftest test-parallel-reduce-nil-pool ()
  (test-parallel-reduce nil))

(deftest test-eval-repeatedly-async-state-nil-pool ()
  (test-eval-repeatedly-async-state nil))

;;; Code to create a locally running Swank master and several Swank workers.

(defconst +master-port+ 12345)

(defvar *master-server* nil)

(defun ensure-master-server (port)
  (unless *master-server*
    (let ((swank::*loopback-interface* (sb-unix:unix-gethostname)))
      (swank:create-server :port port :dont-close t))
    (setf *master-server* t)))

(defconst +worker-base-port+ 12346)

(defun create-workers (base-port worker-count)
  "Creates WORKER-COUNT workers, each running in a thread and listening on a
separate port number starting with BASE-PORT."
  (loop repeat worker-count
        for port from base-port
        do (let ((port port)
                 ;; Make thread-local copies of the global state required for each worker, so
                 ;; multiple workers can run happily in the same Lisp.
                 (swank-crew::*replay-forms-counts-lock* (bordeaux-threads:make-lock))
                 (swank-crew::*replay-forms-counts* (make-hash-table)))
             (bordeaux-threads:make-thread (lambda () (swank:create-server :port port))
                                           :name (format nil "local worker ~D" port)))))

(defmacro with-local-workers ((pool worker-count) &body body)
  "Wraps BODY in a LET form where POOL is bound to a newly created worker pool
containing WORKER-COUNT workers, each running in a thread.  Arranges for the
workers to be disconnected when control exits BODY."
  `(let ((*rex-port* +master-port+))
     (ensure-master-server +master-port+)
     (create-workers +worker-base-port+ ,worker-count)
     (let ((,pool (connect-local-workers +worker-base-port+ ,worker-count)))
       (unwind-protect
            (progn ,@body)
         (when ,pool
           (disconnect-workers ,pool))))))

;;; Tests that use a local worker pool, where each worker runs in a thread.

(deftest test-connect-to-master ()
  (with-local-workers (pool 3)
    (swank-client:with-slime-connection (master (sb-unix:unix-gethostname) +master-port+)
      (is (= (swank-client:slime-eval '(+ 1 1) master) 2)))
    (is (= (worker-count pool) 3))))

(deftest test-eval-form-all-workers-local-pool ()
  (with-local-workers (pool 3)
    (test-eval-form-all-workers pool)))

(deftest test-eval-form-repeatedly-local-pool ()
  (with-local-workers (pool 10)
    (test-eval-form-repeatedly pool)))

(deftest test-parallel-mapcar-local-pool ()
  (with-local-workers (pool 3)
    (test-parallel-mapcar pool)))

(deftest test-parallel-reduce-local-pool ()
  (with-local-workers (pool 3)
    (test-parallel-reduce pool)))

(deftest test-eval-repeatedly-async-state-local-pool ()
  (with-local-workers (pool 3)
    (test-eval-repeatedly-async-state pool)))

;;; Test debugging variables.

(defvar *last-form* nil)
(defvar *last-random* nil)
(defvar *last-repeated-eval-work-function* nil)

(defun save-debugging-variables (form random)
  (setf *last-form* form
        *last-random* random))

(deftest test-debugging-variables ()
  (setf *last-form* nil
        *last-random* nil
        *last-repeated-eval-work-function* nil)
  (let ((form `(progn (save-debugging-variables swank-crew::*last-form-evaled*
                                                swank-crew::*last-random-state*)
                      (lambda ()
                        (setf *last-repeated-eval-work-function*
                              swank-crew::*last-repeated-eval-work-function*)
                        42))))
    (with-local-workers (pool 1)
      (is (equal (eval-form-repeatedly pool 1 form) '(42))))
    (is (equal *last-form* form))
    (is (random-state-p *last-random*))
    (is (= (funcall *last-repeated-eval-work-function*) 42))))
