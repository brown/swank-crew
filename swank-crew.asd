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

(defsystem swank-crew
  :name "Swank Crew"
  :description "Distributed master/worker computing framework."
  :long-description
"Swank Crew is a framework for developing distributed master/worker
applications.  It uses Slime's Swank protocol to transport data between
machines, making the debugging of distributed applications easier."
  :version "1.5"
  :author "Robert Brown <robert.brown@gmail.com>"
  :license "New BSD license.  See the copyright messages in individual files."
  :depends-on (com.google.base
               bordeaux-threads
               swank-client)
  :in-order-to ((test-op (test-op swank-crew/test)))
  :components
  ((:file "package")
   (:file "master" :depends-on ("package"))
   (:file "worker" :depends-on ("package"))))

(defsystem swank-crew/test
  :name "Swank Crew test"
  :description "Test code for package SWANK-CREW."
  :version "1.5"
  :author "Robert Brown <robert.brown@gmail.com>"
  :license "New BSD license.  See the copyright messages in individual files."
  :depends-on (swank-crew hu.dwim.stefil)
  :components
  ((:file "swank-crew-test")))

(defmethod perform ((operation test-op) (component (eql (find-system 'swank-crew/test))))
  (symbol-call 'swank-crew-test 'test-swank-crew))
