(in-package :cl-notebook)
; System initialization and related functions

(defun read-statics ()
  "Used to read the cl-notebook static files into memory.
Only useful during the build process, where its called with an --eval flag."
  (setf *static-files* (make-hash-table :test #'equal))
  (flet ((read-file (filename)
	   (with-open-file (stream filename :element-type '(unsigned-byte 8))
	     (let ((data (make-array (list (file-length stream)))))
	       (read-sequence data stream)
	       data))))
    (let ((root (asdf:system-source-directory :cl-notebook)))
      (setf *quicklisp-file* (read-file (merge-pathnames "quicklisp.lisp" root)))
      (cl-fad:walk-directory
       (sys-dir (merge-pathnames "static" root))
       (lambda (filename)
	 (unless (eql #\~ (last-char filename))
	   (setf (gethash filename *static-files*) (read-file filename))))))))

(defun write-statics (&key force?)
  (when *static-files*
    (loop for k being the hash-keys of *static-files*
       for v being the hash-values of *static-files*
       do (let ((file (if (string= "_notebook" (pathname-name k))
                          (merge-pathnames (pathname-name k) *books*)
                          (merge-pathnames (stem-path k "static") *storage*))))
            (unless (and (cl-fad:file-exists-p file) (not force?))
              (format t "   Writing ~a ...~%" file)
              (ensure-directories-exist file)
              (with-open-file (stream file :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede :if-does-not-exist :create)
                (write-sequence v stream)))))
    (setf *static-files* nil)))

(defun main (&optional argv &key (port 4242) (public? nil))
  (multiple-value-bind (params) (parse-args! argv)
    (flet ((dir-exists? (path) (cl-fad:directory-exists-p path)))
      (let ((p (or (get-param '(:p :port) params) port))
	    (host (if (or (get-param '(:o :open :public) params) public?) usocket:*wildcard-host* #(127 0 0 1))))
	(format t "Initializing storage directories...~%")
	(setf *storage* (sys-dir (merge-pathnames ".cl-notebook" (user-homedir-pathname)))
	      *books* (sys-dir (merge-pathnames "books" *storage*)))
	(unless *static*
	  (format t "Initializing static files...~%")
	  (setf *static* (sys-dir (merge-pathnames "static" *storage*)))
	  (write-statics :force? (get-param '(:f :force) params)))

	(format t "Checking for quicklisp...~%")
	(if (find-package :quicklisp)
	    (format t "   quicklisp already loaded...~%")
	    (let ((ql-dir
		   (or (dir-exists? "quicklisp")
		       (dir-exists? (merge-pathnames "quicklisp" (user-homedir-pathname)))
		       (dir-exists? (merge-pathnames "quicklisp" *storage*)))))
	      (cond (ql-dir
		     (format t "   Loading quicklisp from ~s...~%" ql-dir)
		     (load (merge-pathnames "setup.lisp" ql-dir)))
		    (t
		     (format t "   No quicklisp found...~%")
		     (let ((ql-setup-file (merge-pathnames "quicklisp.lisp" *storage*)))
		       (format t "   TODO auto-install quicklisp to '~~/.cl-notebook/quicklisp/' at this point~%")
		       (format t "   Writing quicklisp.lisp ...~%")
		       (with-open-file (stream ql-setup-file :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede :if-does-not-exist :create)
			 (write-sequence *quicklisp-file* stream))
		       (load ql-setup-file)
		       (funcall
			(intern "INSTALL" :quicklisp-quickstart)
			:path (cl-fad:pathname-as-directory (merge-pathnames "quicklisp" *storage*))))))
	      (setf *quicklisp-file* nil)))

	(in-package :cl-notebook)
	(format t "Loading books...~%")
	(dolist (book (cl-fad:list-directory *books*))
	  (format t "   Loading ~a...~%" book)
	  (load-notebook! book))
	(define-file-handler *static* :stem-from "static")

	(when (get-param '(:d :debug) params)
	  (format t "Starting in debug mode...~%")
	  (house::debug!))

	(format t "Listening on '~s'...~%" p)
	#+ccl (setf ccl:*break-hook*
		    (lambda (cond hook)
		      (declare (ignore cond hook))
		      (ccl:quit)))
	#-sbcl(start p host)
	#+sbcl(handler-case
		  (start p host)
		(sb-sys:interactive-interrupt (e)
		  (declare (ignore e))
		  (cl-user::exit)))))))

(defun main-dev ()
  (house::debug!)
  (setf *static* (sys-dir (merge-pathnames "static" (asdf:system-source-directory :cl-notebook))))
  (bt:make-thread
   (lambda () (main))))
