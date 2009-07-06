(in-package :sykobot)

;; These are only bound within the body of commands.
(defvar *bot*)
(defvar *message*)
(defvar *sender*)
(defvar *channel*)

;;; Command definition
(let ((command-table (make-hash-table :test #'eq)))
  (defun add-command (cmd fn)
    (setf (gethash cmd command-table) fn))

  (defun remove-command (cmd)
    (remhash cmd command-table))

  (defun command-function (cmd)
    (multiple-value-bind (fn hasp)
        (gethash cmd command-table)
      (if hasp fn
          (lambda (bot args sender channel)
            (declare (ignore channel args))
            (send-notice bot sender (format nil "I don't know how to ~A." cmd))))))

  (defun erase-all-commands ()
    (clrhash command-table)))

(defmacro defcommand (name (&optional (regex "") &rest vars) &body body)
  `(add-command ',name
                (lambda (*bot* *message* *sender* *channel*)
                  (declare (ignorable *message* *bot* *sender* *channel*))
                  ,@(if vars
                        `((register-groups-bind ,vars (,regex *message*)
                            ,@body))
                       `(,@body)))))

(deflistener command-listener
  (when (sent-to-me-p *bot* *channel* *message*)
    (respond-to-message *bot* *sender* *channel* *message*)))

(defun cmd-reply (message &rest format-args)
  (send-reply *bot* *sender* *channel* (apply #'format nil message format-args)))

(defun cmd-msg (message &rest format-args)
  (send-msg *bot* *channel* (apply #'format nil message format-args)))

;;; base commands
(defcommand echo ("(.*)" string)
  (cmd-reply string))
(defcommand source ()
  (cmd-reply "http://github.com/zkat/sykobot"))
(defcommand help ()
  (cmd-reply "No."))
(defcommand topic ("(.*)" new-topic)
  (if (< 0 (length new-topic))
      (topic *bot* *channel* new-topic)
      (cmd-msg (topic *bot* *channel*))))
(defcommand ping ()
  (cmd-reply "pong"))
(defcommand shut ("(\\S+)*" arg1)
  (when (equalp arg1 "up")
    (cmd-reply "Fine. Be that way. Tell me to talk when you realize ~
                just how lonely and pathetic you really are.")
    (shut-up *bot*)))
(defcommand talk ()
  (un-shut-up *bot*)
  (cmd-reply "bla bla bla bla. There, happy?"))
(defcommand hi ()
  (cmd-reply "Go away."))
(defcommand give ("(\\S+) (\\S+) (.*)$" new-target new-command new-args)
  (answer-command *bot* new-command new-args new-target *channel*))

;;; Character Decoding
(defcommand code->char ("(\\S+)*" code-string)
  (let ((code (if code-string (parse-integer code-string :junk-allowed T) 0)))
    (cmd-msg "~:[Invalid code~;~:*~A~]" (and (integerp code) (/= code 127) (>= code 32)
                                             (code-char code)))))

(defcommand char->code ("(\\S+)*" char-string)
  (let ((code (and char-string (char-code (elt char-string 0)))))
    (cmd-msg  "~:[Invalid character~;~A~]"
              (and (integerp code) (/= code 127) (>= code 32))
              code)))

;;; General web functionality
(defun url-info (url)
  (multiple-value-bind (body status-code headers uri)
      (drakma:http-request url)
    (declare (ignore status-code headers))
    (values (multiple-value-bind (match vec)
                (scan-to-strings
                 (create-scanner
                  "<title[.\\s]*>\\s*(.+)\\s*</title[\\s.]*>"
                  :case-insensitive-mode t) body)
              (declare (ignore match))
              (if (< 0 (length vec))
                  (decode-html-string (elt vec 0))
                  nil))
            (with-output-to-string (s)
              (puri:render-uri uri s)))))

(defun decode-html-string (string)
  (html-entities:decode-entities string))

(defun search-url (engine query)
  (format nil engine (regex-replace-all "\\s+" query "+")))

;;; Google
(defcommand google ("(.*)" query)
  (multiple-value-bind (title url)
      (google-search query)
    (cmd-reply "~:[~;~A ~]<~A>" title title url)))

(defun google-search (query)
  (url-info (search-url
             "http://google.com/search?filter=1&safe=on&q=~A&btnI"
             query)))

;;; CLiki search
(defcommand cliki ("(.*)" query)
  (multiple-value-bind (links numlinks)
      (cliki-urls query)
    (cmd-reply "I found ~D result~:P.~@[ Check out <~A>.~]" numlinks (car links))))

(defun cliki-urls (query)
  (let ((links NIL)
        (page (drakma:http-request
               (search-url "http://www.cliki.net/admin/search?words=~A"
                           query))))
    (do-register-groups (url)
        ("\\d <b><a href=\"(.*?)\">(.*?)<" page)
      (push url links))
    (values (nreverse links)
            (or (parse-integer
                 (or (scan-to-strings "(\\d*) results? found" page)
                     "")
                 :junk-allowed T)
                0))))

;;; kiloseconds
(defcommand kiloseconds ("(.*)" zone)
  (let* ((parsed-zone (if (= 0 (length zone))
                          0
                          (parse-integer zone :junk-allowed t)))
         (ks-time (get-ks-time parsed-zone)))
    (cmd-reply "The time in GMT~A is ~3$ ks."
               (if (or (= parsed-zone 0) (plusp parsed-zone))
                   (format nil "+~A" parsed-zone)
                   (format nil "~A" parsed-zone))
               ks-time)))

(defun get-ks-time (&optional (gmt-diff 0))
  (multiple-value-bind
        (seconds minutes hours date month year day light zone)
      (get-decoded-time)
    (declare (ignore date month year day light))
    (/ (+ seconds
          (* 60 (+ minutes
                   (* 60 (mod (+ hours zone gmt-diff) 24)))))
       1000)))

;;; Parrot
(deflistener parrot
  (cmd-msg *message*))
(defcommand parrot ()
  (activate-listener 'parrot))
(defcommand noparrot ()
  (deactivate-listener 'parrot))

;;; Facts
(defparameter *facts-file-path* (ensure-directories-exist
                                 (merge-pathnames ".sykobot/fact-table.db" (user-homedir-pathname))))
(let ((fact-table (make-hash-table :test #'equalp)))

  (defun set-fact (noun info)
    (setf (gethash noun fact-table) info)
    (save-facts))
  
  (defun get-fact (noun)
    (multiple-value-bind (info hasp)
        (gethash noun fact-table)
      (if hasp
          info
          (format nil "I know nothing about ~A" noun))))

  (defun erase-all-facts ()
    (clrhash fact-table)
    (save-facts))

  (defun save-facts ()
    (cl-store:store fact-table *facts-file-path*))

  (defun load-facts ()
    (setf fact-table (if (probe-file *facts-file-path*)
                         (cl-store:restore *facts-file-path*)
                         (make-hash-table :test #'equalp))))
  ) ;end fact table

(defun split-into-sub-statements (statement)
  (split "\\s*(,|but|however|whereas|although|\\;|\\.)\\s*" statement))

(deflistener scan-for-fact
  (loop for statement in (split-into-sub-statements *message*)
     do (do-register-groups (article noun verb info)
            (".*?([a|an|the|this|that]*)\\s*(\\w+)\\s+(is|are|isn't|ain't)\\s+(.+)"
             statement)
          (set-fact noun (format nil "~A ~A ~A ~A" article noun verb info)))))

(defcommand fact ("(\\S+)*" topic)
  (cmd-msg (get-fact topic)))

;;; URLs
(deflistener scan-for-url
  (when (and (has-url-p *message*)
             (not (string-equal *sender* (nickname *bot*))))
    (handler-case
        (multiple-value-bind (title url)
            (url-info (grab-url *message*))
          (cmd-msg (format nil "Title: ~A (at ~A)" (or title "<unknown title>") (puri:uri-host (puri:uri url)))))
      (error ()
        (values)))))

(defun has-url-p (string)
  (when (scan "https?://.*[.$| |>]" string) t))

(defun grab-url (string)
  (find-if #'has-url-p (split "[\\s+><,]" string)))
