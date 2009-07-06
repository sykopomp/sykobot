(defpackage #:sykobot
  (:use :cl :cl-ppcre :sheeple)
  (:export :sykobot :run-bot :connect :disconnect :join :part
           :identify :nick :send-notice :send-msg :topic :add-command
           :remove-command :connection :nickname :server :password
           :*default-channels* :*server* :*identify-with-nickserv?*
           :*nickserv-password* :*nickname* :*cmd-prefix*))

(defpackage #:sykobot-user
  (:use :cl :sykobot :sheeple :cl-ppcre))
(in-package :sykobot)

(defproto sykobot ()
  ((connection nil)
   (msg-loop-thread nil)
   (nickname "sykobot")
   (server "irc.freenode.net")
   (password nil)
   (mode :normal)
   (aliases nil)))
(defvar *active-bots* nil)

;;;
;;; IRC connection
;;;
(defmessage run-bot (bot))
(defmessage connect (bot server &optional password))
(defmessage disconnect (bot &optional message))
(defmessage join (bot channel))
(defmessage part (bot channel))
(defmessage identify (bot password))

(defreply run-bot ((bot (proto 'sykobot)))
  (connect bot (server bot) (password bot))
  (pushnew bot *active-bots*))

(defreply connect ((bot (proto 'sykobot)) server &optional password)
  (setf (connection bot) (irc:connect :nickname (nickname bot) :server server :password password))
  (irc:add-hook (connection bot) 'irc:irc-privmsg-message
                (lambda (msg)
                  (handler-bind ((cl-irc:no-such-reply (lambda (c)
                                                         (let ((r (find-restart 'continue c)))
                                                           (when r (invoke-restart r))))))
                    (msg-hook bot msg))))
  (setf (msg-loop-thread bot)
        (bt:make-thread
         (lambda ()
           (handler-bind ((cl-irc:no-such-reply
                           (lambda (c)
                             (let ((r (find-restart 'continue c)))
                               (when r (invoke-restart r))))))
             (irc:read-message-loop (connection bot)))))))

(defreply disconnect ((bot (proto 'sykobot)) &optional message)
  (bt:destroy-thread (msg-loop-thread bot))
  (setf *active-bots* (delete bot *active-bots*))
  (irc:quit (connection bot) (or message (values))))

(defreply join ((bot (proto 'sykobot)) channel)
  (irc:join (connection bot) channel))

(defreply part ((bot (proto 'sykobot)) channel)
  (irc:part (connection bot) channel))

(defreply identify ((bot (proto 'sykobot)) password)
  (send-msg bot "nickserv" (format nil "identify ~A" password)))

;;;
;;; irc functions
;;;
(defmessage nick (bot new-nick))
(defmessage send-notice (bot target message))
(defmessage send-msg (bot channel message))
(defmessage send-reply (bot target channel message))
(defmessage send-action (bot channel action))
(defmessage topic (bot channel &optional new-topic))

(defreply nick ((bot (proto 'sykobot)) new-nick)
  (setf (nickname bot) new-nick)
  (irc:nick (connection bot) new-nick))

(defreply send-notice ((bot (proto 'sykobot)) target message)
  (irc:notice (connection bot) target message))

(defreply send-msg ((bot (proto 'sykobot)) channel message)
  (irc:privmsg (connection bot) channel (or message "")))

(defreply send-reply ((bot (proto 'sykobot)) target channel message)
  (send-msg bot channel (format nil "~A: ~A" target message)))

(defreply send-action ((bot (proto 'sykobot)) channel action)
  (send-msg bot channel (format nil "~AACTION ~A~A"
                                (code-char 1) action (code-char 1))))

(defreply topic ((bot (proto 'sykobot)) channel &optional new-topic)
  (if new-topic
      (irc:topic- (connection bot) channel new-topic)
      (irc:topic (irc:find-channel (connection bot) channel))))

;;;
;;; Message processing
;;;
(defmessage msg-hook (bot msg))
(defmessage process-message (mode bot sender channel message))
(defmessage shut-up (bot))
(defmessage un-shut-up (bot))
(defmessage respond-to-message (bot sender channel message))
(defmessage answer-command (bot cmd args sender channel))

(defreply msg-hook ((bot (proto 'sykobot)) msg)
  (let ((sender (irc:source msg))
        (channel (car (irc:arguments msg)))
        (message (second (irc:arguments msg))))
    (process-message (mode bot) bot sender channel message)))

(defreply process-message ((mode :normal) (bot (proto 'sykobot))
                           sender channel message)
  (declare (ignore mode))
  (call-listeners bot sender channel
                  (expand-aliases bot message)))

(defreply process-message ((mode :silent) (bot (proto 'sykobot))
                           sender channel message)
  (declare (ignore mode))
  (when (sent-to-me-p bot channel message)
    (let ((command (car (split "\\s+" (scan-string-for-direct-message bot channel message) :limit 2))))
      (when (string-equal command "talk")
        (send-reply bot sender channel "bla bla bla bla. There, happy?")
        (un-shut-up bot)))))

(defreply shut-up ((bot (proto 'sykobot)))
  (setf (mode bot) :silent))

(defreply un-shut-up ((bot (proto 'sykobot)))
  (setf (mode bot) :normal))

(defreply respond-to-message ((bot (proto 'sykobot)) sender channel message)
  (let* ((string (scan-string-for-direct-message bot channel message))
         (command+args (split "\\s+" string :limit 2)))
    (handler-case
        (answer-command bot (car command+args) (cadr command+args) sender channel)
      (error (e)
        (send-reply bot sender channel (format nil "An error occurred: ~A" e))))))

(defreply answer-command ((bot (proto 'sykobot)) (cmd (proto 'string)) args sender channel)
  (answer-command bot (intern (string-upcase cmd) :sykobot) args sender channel))

(defreply answer-command ((bot (proto 'sykobot)) (cmd (proto 'symbol)) args sender channel)
  (let ((fn (command-function cmd)))
    (funcall fn bot args sender channel)))

(defun sent-to-me-p (bot channel message)
  (when (scan-string-for-direct-message bot channel message)
    t))

(defparameter *cmd-prefix* "@")
(defmessage scan-string-for-direct-message (bot channel message))
(defreply scan-string-for-direct-message ((bot (proto 'sykobot)) channel message)
  (cond ((equal channel (nickname bot))
         message)
        ((scan (format nil "^~A: " (nickname bot)) message)
         (regex-replace (format nil "^~A: " (nickname bot)) message ""))
        ((scan (format nil "^~A, " (nickname bot)) message)
         (regex-replace (format nil "^~A, " (nickname bot)) message ""))
        ((scan (format nil "^~A+" *cmd-prefix*) message)
         (regex-replace (format nil "^~A+" *cmd-prefix*) message ""))))

;;;
;;; Aliases
;;;
(defmessage add-alias (bot alias expansion))
(defmessage remove-alias (bot alias))
(defmessage expand-aliases (bot message))

(defreply add-alias ((bot (proto 'sykobot)) alias expansion)
  (setf (aliases bot) (acons alias expansion (aliases bot))))

(defreply remove-alias ((bot (proto 'sykobot)) alias)
  (setf (aliases bot) (delete alias (aliases bot) :count 1
                              :test #'string-equal :key #'car)))

(defreply expand-aliases ((bot (proto 'sykobot)) message)
  (loop while
       (loop for (alias . expansion) in (aliases bot)
          for (new changedp) =
            (multiple-value-list (regex-replace-all alias message
                                                    expansion
                                                    :preserve-case t))
          when changedp do
            (setf message new)
            (return t))
       finally (return message)))