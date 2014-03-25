(in-package #:cl-notebook)

(defvar *notebooks* 
  (make-hash-table :test 'equal))

(defmethod new-cell! ((book fact-base) &optional (cell-type :code))
  (multi-insert! book `((:cell nil) (:cell-type ,cell-type) (:contents "") (:value ""))))

(defmethod remove-notebook! (name)
  (remhash name *notebooks*))

(defun new-notebook! (name)
  (let ((book (make-fact-base :indices '(:a :b :c :ab) :id name)))
    (insert-new! book :notebook-name name)
    (new-cell! book)
    (unless (gethash name *notebooks*)
      (setf (gethash name *notebooks*) book))))

(defun load-notebook! (name)
  (setf (gethash name *notebooks*) (load! name :indices '(:a :b :c :ab))))

(defun get-notebook (name)
  (gethash name *notebooks*))

(define-closing-handler (root) ()
  (with-html-output-to-string (s nil :prologue t :indent t)
    (:html
     (:head
      (:title "cl-notebook")
      (:script :type "text/javascript" :src "/js/base.js")
      (:script :type "text/javascript" :src "/js/main.js")
      (:script :type "text/javascript" :src "static/js/native-sortable.js")

      (:link :rel "stylesheet" :href "static/css/codemirror.css")
      (:link :rel "stylesheet" :href "static/css/dialog.css")
      (:link :rel "stylesheet" :href "static/css/show-hint.css")

      (:script :type "text/javascript" :src "static/codemirror-3.22/lib/codemirror.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/mode/commonlisp/commonlisp.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/edit/closebrackets.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/edit/matchbrackets.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/search/search.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/search/searchcursor.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/search/match-highlighter.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/selection/active-line.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/selection/mark-selection.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/hint/show-hint.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/hint/anyword-hint.js")
      (:script :type "text/javascript" :src "static/codemirror-3.22/addon/dialog/dialog.js"))
     (:body
      (:h1 "Hello!")
      (:textarea :class "cell" :style "display: none;")
      (:pre :class "result")))))

(defun single-eval-for-js (s-exp)
  (capturing-error (format nil "~a" s-exp)
    (let ((res (multiple-value-list (ignoring-warnings (eval s-exp)))))
      (loop for v in res collect (list (type-label v) (format nil "~s" v))))))

(defun read-all-from-string (str)
  (let ((len (length str))
	(start 0))
    (loop for (s-exp next) = (multiple-value-list (read-from-string str nil nil :start start))
       do (setf start next)
       collect s-exp
       until (or (not (numberp next)) (= len next)))))

(defun eval-from-string (str)
  (let ((len (length str))
	(start 0))
    (loop for (s-exp next) = (multiple-value-list (capturing-error nil (read-from-string str nil nil :start start)))
       for (evaled eval-error?) = (unless (eq next :error) (multiple-value-list (single-eval-for-js s-exp)))
       if (eq next :error) collect s-exp into res-list
       else collect evaled into res-list
	 
       do (setf start next)
       when (or (eq next :error) (eq eval-error? :error)) do (return res-list)
       when (and next (numberp next) (= len next)) do (return (last res-list)))))

(defun eval-capturing-stdout (string)
  (let* ((res nil)
	 (stdout (with-output-to-string (*standard-output*)
		   (setf res (eval-from-string string)))))
    (values res stdout)))

(defun js-eval (thing)
  (with-js-error
    (multiple-value-bind (res stdout) (eval-capturing-stdout thing)
      (alist
       :result res
       :stdout stdout))))

(define-json-handler (eval) ((thing :string))
  (js-eval thing))

(defun html-tree-to-string (html-tree)
  (cadar (cl-who::tree-to-commands 
	  (if (keywordp (car html-tree))
	      (list html-tree)
	      html-tree) nil)))

(defun js-whoify (thing)
  (with-js-error
    (alist :result (html-tree-to-string (read-all-from-string thing)))))

(define-json-handler (whoify) ((thing :string))
  (js-whoify thing))

(define-json-handler (notebook/current) ((book :notebook))
  (current book))

(define-json-handler (notebook/eval-to-cell) ((book :notebook) (cell-id :integer) (contents :string))
  (let* ((cont-fact (first (lookup book :a cell-id :b :contents)))
	 (val-fact (first (lookup book :a cell-id :b :value)))
	 (cell-type (caddar (lookup book :a cell-id :b :cell-type)))
	 (res (case cell-type
		(:markup (js-whoify contents))
		(t (js-eval contents)))))
    (when (and cont-fact val-fact res)
      (delete! book cont-fact)
      (delete! book val-fact)
      (insert! book (list cell-id :contents contents))
      (insert! book (list cell-id :value res))
      (write-delta! book)
      (current book))))

(define-json-handler (notebook/new-cell) ((book :notebook) (cell-type :cell-type))
  (new-cell! book cell-type)
  (write-delta! book)
  (current book))

(define-json-handler (notebook/reorder-cells) ((book :notebook) (cell-order :json))
  (awhen (lookup book :b :cell-order)
    (delete! book (car it)))
  (insert-new! book :cell-order cell-order)
  (write-delta! book)
  (alist :result :ok))

(define-json-handler (notebook/kill-cell) ((book :notebook) (cell-id :integer))
  (loop for f in (lookup book :a cell-id) do (delete! book f))
  (write-delta! book)
  (current book))

(defun main (&optional argv) 
  (declare (ignore argv))
  (define-file-handler "static")
  (load-notebook! "test-book")
  (start 4242))
