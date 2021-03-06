(in-package :data-table)
(cl-interpol:enable-interpol-syntax)

(defun exec (command)
  (if clsql-sys:*default-database*
    (clsql-sys:execute-command command)
    (warn "No Database (bind clsql-sys:*default-database*) : cant exec ~A" command)))

(defun has-table? (table)
  (clsql-sys:table-exists-p table))


(defmethod get-data-table ( query &key auto-type )
  "When Auto-type is true it will work to ensure everything is in a reasonable data-type and document what type that is"
  (multiple-value-bind (rows colnames) (clsql:query query :flatp T)
    (let ((dt (make-instance 'data-table :rows rows :column-names colnames )))
      (when auto-type
	(coerce-data-table-of-strings-to-types dt))
      dt)))

(defun sql-escaped-column-names (data-table
                                 &key
                                 (transform #'english->postgres))
  (iter
    (for c in (column-names data-table))
    (unless (stringp c) (setf c (princ-to-string c)))
    (when transform (setf c (funcall transform c)))
    (collect c)))

(defun clean-name-for-db (name)
  (cl-ppcre:regex-replace-all
   #?r"(_|\(|\)|,|\.|\+|-|\?|\||\s)+"  (princ-to-string name) " "))

(defun english->mssql (name)
  (symbol-munger:english->studly-case
   (clean-name-for-db name)))

(defun english->postgres (name)
  (symbol-munger:english->underscores
   (string-downcase
    (clean-name-for-db name))))

(defun sql-escape-column-names!
    (dt &key (transform #'english->postgres))
  (setf (column-names dt)
        (sql-escaped-column-names
         dt :transform transform)))

(defmethod is-clsql-date-type? (type)
  (or (subtypep type 'clsql-sys:wall-time)
      (subtypep type 'clsql-sys:date)))

(defmethod %to-clsql-date (val)
  (clsql-helper:convert-to-clsql-datetime val))

(defun next-highest-power-of-two (l)
  (expt 2 (1+ (truncate (log (max l 1) 2)))))

(defun mssql-db-types-for-data-table (dt)
  (iter (for type in (column-types dt))
    (for i upfrom 0)
    (collect
	(cond
	  ((subtypep type 'string)
	   (iter (for v in (data-table-value dt :col-idx i))
              (maximizing (next-highest-power-of-two (length v)) into len)
              (finally (return
                         (if (< len 8000)
                             #?"varchar (${len})"
                             "text")))))
	  ((subtypep type 'integer)
	   (iter (for v in (data-table-value dt :col-idx i))
	     (when v
	       (maximizing v into biggest)
	       (minimizing v into smallest))
	     (finally (return
			(if (or (and smallest (< smallest -2147483648))
				(and biggest (< 2147483647 biggest)))
			    "bigint" "int")))))
	  (T (clsql-helper:db-type-from-lisp-type type))))))

(defun ensure-mssql-table-for-data-table (data-table table-name
                                          &key (should-have-serial-id "Id")
                                          dry-run? print?
                                          excluded-columns)
  (when (member should-have-serial-id (column-names data-table) :test #'string-equal)
    (error "serial id name matches an existing column in the data table. You must rename one."))
  (sql-escape-column-names! data-table :transform #'english->mssql)
  (let* ((dt data-table)
         (sql-types (mssql-db-types-for-data-table data-table))
         (cmd
           (collectors:with-string-builder (body :delimiter #?",\n  ")
             (when should-have-serial-id
               (body #?"${should-have-serial-id} int IDENTITY (1,1) PRIMARY KEY"))
             (iter (for type in sql-types)
               (for c in (column-names dt))
               (unless (member c excluded-columns :test #'string-equal)
                 (body (format nil "~a ~a" c type))))
             #?"CREATE TABLE dbo.${table-name} ( ${(body)} );")))
    (when print?
      (format T cmd))
    (unless (or (has-table? table-name)
                dry-run?)
      (exec cmd))
    cmd))


(defun ensure-postgres-table-for-data-table (data-table table-name
                                             &key (should-have-serial-id "id") (schema "public")
                                             dry-run? print?
                                             excluded-columns)
  (when (member should-have-serial-id (column-names data-table) :test #'string-equal)
    (error "serial id name matches an existing column in the data table. You must rename one."))
  (let* ((dt data-table))
    (sql-escape-column-names! dt)
    (unless (clsql-sys:table-exists-p table-name)
      (let ((cmd (collectors:with-string-builder (body :delimiter #?",\n  ")
                   (when should-have-serial-id
                     (body #?"\"${should-have-serial-id}\" serial PRIMARY KEY"))
                   (iter (for type in (column-types dt))
                     (for c in (column-names dt))
                     (unless (member c excluded-columns :test #'string-equal)
                       (body (format nil "~a ~a" c (clsql-helper:db-type-from-lisp-type type)))))
                   #?"CREATE TABLE ${schema}.${table-name} ( ${(body)} );")))
        (when print?
          (format T cmd))
        (unless dry-run?
          (exec cmd))))))

(defun duplicates (sequence &key (test #'eql)
                   &aux res seen)
  "returns a list of duplicate elements"
  (dolist (item sequence res)
    (if (find item seen :test test)
        (push item res)
        (push item seen)))
  res)

(define-condition duplicate-column-name (error)
  ((name :reader name :initarg :name)))
(defmethod print-object ((o duplicate-column-name) s)
  (print-unreadable-object (o s :type t :identity t)
    (format s "Duplicate column name: ~a" (name o))))

(defun check-for-duplicate-columns (data-table)
  "looks for duplicate column names, signaling 'duplicate-column-name errors with useful restarts"
  (when-let ((dupes (duplicates (column-names data-table) :test #'string-equal)))
    (labels
        ((add-suffix (d i)
           "returns the column with appropriate number suffix"
           ;;need do this outside the iterate body because iter re-interprets 'count
           (format nil "~a_~d" d (count d dupes :test #'string-equal :end i)))
         (column-pos (d &optional (start 0))
           "returns the position of this column name in the data table"
           (position d (column-names data-table) :test #'string= :start start))
         (second-position (d)
           "returns the position of the second occurence of this column name in the data table"
           (column-pos d (1+ (column-pos d))))
         (%check-for-duplicate-columns (data-table dupes)
           "signals 'duplicate-column-name errors for each dupe with useful restarts"
           (iter
             (for i from 1)
             (for d in dupes)
             (for new-name = (add-suffix d i))
             (restart-case
                 (error 'duplicate-column-name :name d)
               (add-numeric-suffix ()
                 :report (lambda (s)
                           (format s "add a numeric suffix to make this name unique: ~a => ~a"
                                   d new-name))
                 (setf (nth (second-position d) (column-names data-table))
                       new-name))))))
      (restart-case
          (%check-for-duplicate-columns data-table dupes)
        (add-numeric-suffix-to-all ()
          :report "add numeric suffixes to all duplicated columns"
          (handler-bind ((duplicate-column-name
                           #'(lambda (c)
                               (declare (ignore c))
                               (invoke-restart 'add-numeric-suffix))))
            (%check-for-duplicate-columns data-table dupes)))))))

(defun ensure-table-for-data-table (data-table table-name &rest keys
                                    &key should-have-serial-id schema
                                    excluded-columns dry-run? print?)
  (declare (ignore should-have-serial-id schema excluded-columns dry-run? print?))
  (check-for-duplicate-columns data-table)
  (apply
   (ecase (clsql-sys::database-underlying-type clsql-sys:*default-database*)
     (:mssql #'ensure-mssql-table-for-data-table)
     (:postgresql #'ensure-postgres-table-for-data-table))
   data-table table-name keys))

(defun make-row-importer (data-table table-name &key schema excluded-columns row-fn)
  (let* ((db-kind (clsql-sys::database-underlying-type clsql-sys:*default-database*))
         (schema (or schema
                     (ecase db-kind
                       (:mssql "dbo")
                       (:postgresql "public"))))
         (cols (remove-if #'(lambda (c) (member c excluded-columns :test #'string-equal))
                          (sql-escaped-column-names
                           data-table
                           :transform (ecase db-kind
                                        (:mssql #'english->mssql)
                                        (:postgresql #'english->postgres))))))

    #'(lambda (row)
        (let ((cl-interpol:*list-delimiter* ",")
              (*print-pretty* nil)
              (data (iter (for d in row)
                      (for column from 0)
                      (for c in (column-names data-table))
                      (for ty in (column-types data-table))
                      (unless (member c excluded-columns :test #'string-equal)
                        (when (stringp d)
                          (setf d (trim-and-nullify d)))
                        (collect
                            (clsql-helper:format-value-for-database
                             (restart-case (data-table-coerce d ty)
                               (assume-column-is-string ()
                                 :report "assume this column is a string type and re-coerce"
                                 (setf (nth column (column-types data-table)) 'string)
                                 (data-table-coerce d 'string)))))))))
          (when (or (null row-fn)
                    (funcall row-fn data schema table-name cols))
            (tagbody
             try-again
               (restart-case
                   (exec #?"INSERT INTO ${schema}.${table-name} (@{ cols }) VALUES ( @{data} )")
                 (try-again ()
                   :report "Try running this insert again."
                   (go try-again))
                 (skip ()
                   :report "Skip importing this row"))))))))

(defun import-data-table (data-table table-name &key excluded-columns schema row-fn)
  (mapc (make-row-importer data-table table-name
                           :excluded-columns excluded-columns :row-fn row-fn :schema schema)
        (rows data-table)))
