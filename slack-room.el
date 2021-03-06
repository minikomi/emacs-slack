;;; slack-room.el --- slack generic room interface    -*- lexical-binding: t; -*-

;; Copyright (C) 2015  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'eieio)
(require 'lui)
(require 'slack-request)
(require 'slack-message)

(defvar slack-current-room-id)
(defvar slack-current-team-id)
(defvar slack-buffer-function)
(defconst slack-room-pins-list-url "https://slack.com/api/pins.list")

(defclass slack-room ()
  ((name :initarg :name :type string)
   (id :initarg :id)
   (created :initarg :created)
   (has-pins :initarg :has_pins)
   (last-read :initarg :last_read :type string :initform "0")
   (latest :initarg :latest)
   (oldest :initarg :oldest)
   (unread-count :initarg :unread_count)
   (unread-count-display :initarg :unread_count_display :initform 0 :type integer)
   (messages :initarg :messages :initform ())
   (team-id :initarg :team-id)))

(defgeneric slack-room-name (room))
(defgeneric slack-room-history (room team &optional oldest after-success sync))
(defgeneric slack-room-update-mark-url (room))

(defun slack-room-create (payload team class)
  (cl-labels
      ((prepare (p)
                (plist-put p :members
                           (append (plist-get p :members) nil))
                (plist-put p :team-id (oref team id))
                (plist-put p :last_read "0")
                p))
    (let* ((attributes (slack-collect-slots class (prepare payload)))
           (room (apply #'make-instance class attributes)))
      (oset room latest (slack-message-create (plist-get payload :latest) team :room room))
      room)))

(defmethod slack-room-subscribedp ((_room slack-room) _team)
  nil)

(defmethod slack-room-buffer-name ((room slack-room))
  (concat "*Slack*"
          " : "
          (slack-room-display-name room)))

(defmacro slack-room-with-buffer (room team &rest body)
  (declare (indent 2) (debug t))
  `(let ((buf (slack-buffer-create ,room ,team)))
     (with-current-buffer buf
       ,@body)
     buf))

(cl-defun slack-room-create-buffer (room team &key update)
  (with-slots (messages) room
    (if (or update (< (length messages) 1) (string= "0" (oref room last-read)))
        (slack-room-history-request room team)))
  (funcall slack-buffer-function
           (slack-room-with-buffer room team
             (slack-room-insert-messages room buf team))))

(cl-defun slack-room-create-buffer-bg (room team)
  (cl-labels
      ((create-buffer ()
                      (tracking-add-buffer
                       (slack-room-with-buffer room team
                         (slack-room-insert-messages room buf team)))))
    (if (< (length (oref room messages)) 1)
        (slack-room-history-request room team
                                    :after-success #'(lambda () (create-buffer))
                                    :async t)
      (create-buffer))))

(cl-defmacro slack-select-from-list ((alist prompt &key initial) &body body)
  "Bind candidates from selected."
  (let ((key (cl-gensym)))
    `(let* ((,key (let ((completion-ignore-case t))
                    (funcall slack-completing-read-function (format "%s" ,prompt)
                                     ,alist nil t ,initial)))
            (selected (cdr (cl-assoc ,key ,alist :test #'string=))))
       ,@body
       selected)))

(defun slack-room-select (rooms)
  (let* ((alist (slack-room-names
                 rooms
                 #'(lambda (rs)
                     (cl-remove-if #'(lambda (r)
                                       (or (not (slack-room-member-p r))
                                           (slack-room-archived-p r)
                                           (not (slack-room-open-p r))))
                                   rs)))))
    (slack-select-from-list
     (alist "Select Channel: ")
     (slack-room-create-buffer selected
                               (slack-team-find (oref selected team-id))))))

(cl-defun slack-room-list-update (url success team &key (sync t))
  (slack-request
   url
   team
   :success success
   :sync sync))

(defun slack-room-update-messages ()
  (interactive)
  (unless (and (boundp 'slack-current-room-id)
               (boundp 'slack-current-team-id))
    (error "Call From Slack Room Buffer"))
  (let* ((team (slack-team-find slack-current-team-id))
         (room (slack-room-find slack-current-room-id team))
         (cur-point (point)))
    (slack-room-history-request room team)
    (slack-room-with-buffer room team
      (slack-buffer-widen
       (let ((inhibit-read-only t))
         (delete-region (point-min) (marker-position lui-output-marker))))
      (slack-room-insert-previous-link room buf)
      (slack-room-insert-messages room buf team)
      (goto-char cur-point))))

(defun slack-room-find-message (room ts)
  (cl-find-if #'(lambda (m) (string= ts (oref m ts)))
              (oref room messages)
              :from-end t))

(defun slack-room-find-thread-parent (room thread-message)
  (slack-room-find-message room (oref thread-message thread-ts)))

(defun slack-room-find-thread (room ts)
  (let ((message (slack-room-find-message room ts)))
    (when message
      (if (object-of-class-p message 'slack-reply-broadcast-message)
          (progn
            (setq message (slack-room-find-message room (oref message broadcast-thread-ts)))))
      (and message (oref message thread)))))

(defmethod slack-room-team ((room slack-room))
  (slack-team-find (oref room team-id)))

(defmethod slack-room-display-name ((room slack-room))
  (let ((room-name (slack-room-name room)))
    (if slack-display-team-name
        (format "%s - %s"
                (oref (slack-room-team room) name)
                room-name)
      room-name)))

(defmethod slack-room-label-prefix ((_room slack-room))
  "  ")

(defmethod slack-room-unread-count-str ((room slack-room))
  (with-slots (unread-count-display) room
    (if (< 0 unread-count-display)
        (concat " ("
                (number-to-string unread-count-display)
                ")")
      "")))

(defmethod slack-room-label ((room slack-room))
  (format "%s%s%s"
          (slack-room-label-prefix room)
          (slack-room-display-name room)
          (slack-room-unread-count-str room)))

(defmacro slack-room-names (rooms &optional filter)
  `(cl-labels
       ((latest-ts (room)
                   (with-slots (latest) room
                     (if latest (oref latest ts) "0")))
        (sort-rooms (rooms)
                    (nreverse
                     (cl-sort rooms #'string<
                              :key #'(lambda (name-with-room) (latest-ts (cdr name-with-room)))))))
     (sort-rooms
      (cl-loop for room in (if ,filter
                               (funcall ,filter ,rooms)
                             ,rooms)
               collect (cons (slack-room-label room) room)))))

(defmethod slack-room-name ((room slack-room))
  (oref room name))

(defmethod slack-room-update-last-read-p ((room slack-room) ts)
  (not (string> (oref room last-read) ts)))

(defmethod slack-room-update-last-read ((room slack-room) msg)
  (if (slack-room-update-last-read-p room (oref msg ts))
      (oset room last-read (oref msg ts))))

(defmethod slack-room-latest-messages ((room slack-room) messages)
  (with-slots (last-read) room
    (cl-remove-if #'(lambda (m)
                      (or (string< (oref m ts) last-read)
                          (string= (oref m ts) last-read)))
                  messages)))

(defun slack-room-sort-messages (messages)
  (cl-sort messages
           #'string<
           :key #'(lambda (m) (oref m ts))))

(defun slack-room-reject-thread-message (messages)
  (cl-remove-if #'(lambda (m) (slack-message-thread-messagep m))
                messages))

(defmethod slack-room-sorted-messages ((room slack-room))
  (with-slots (messages) room
    (slack-room-sort-messages (copy-sequence messages))))

(defmethod slack-room-set-prev-messages ((room slack-room) prev-messages)
  (slack-room-set-messages
   room
   (cl-delete-duplicates (append (oref room messages)
                                 prev-messages)
                         :test #'slack-message-equal)))

(defun slack-room-gather-thread-messages (messages)
  (cl-labels
      ((groupby-thread-ts (messages acc)
                          (cl-loop for m in messages
                                   do (let ((thread-ts (oref m thread-ts)))
                                        (when (and thread-ts (not (slack-message-thread-parentp m)))
                                          (puthash thread-ts
                                                   (cons m (gethash thread-ts acc))
                                                   acc))))
                          acc)
       (make-threads (table acc)
                     (cl-loop for key being the hash-keys in table using (hash-value value)
                              do (let ((parent (cl-find-if #'(lambda (m)
                                                               (string= key (oref m ts)))
                                                           messages)))
                                   (when parent
                                     (slack-thread-set-messages (oref parent thread) value)
                                     (push parent acc))))
                     acc)
       (remove-duplicates (threads messages)
                          (let ((ret))
                            (if (< 0 (length threads))
                                (progn
                                  (dolist (message messages)
                                    (if (and (oref message thread-ts)
                                             (not (slack-message-thread-parentp message)))
                                        (push message ret)
                                      (let ((thread (cl-find-if #'(lambda (m)
                                                                    (slack-message-equal m message))
                                                                threads)))
                                        (unless thread (push message ret)))))
                                  (setq ret (append ret threads)))
                              (setq ret messages))
                            ret)))
    (let ((thread-messages (groupby-thread-ts messages (make-hash-table :test 'equal))))
      (if (< 0 (length (hash-table-keys thread-messages)))
          (remove-duplicates (make-threads thread-messages nil) messages)
        messages))))

(defmethod slack-room-update-latest ((room slack-room) message)
  (with-slots (latest) room
    (if (or (null latest)
            (string< (oref latest ts) (oref message ts)))
        (setq latest message))))

(defmethod slack-room-set-oldest ((room slack-room) sorted-messages)
  (let ((oldest (and (slot-boundp room 'oldest) (oref room oldest)))
        (maybe-oldest (car sorted-messages)))
    (if oldest
        (when (string< (oref maybe-oldest ts) (oref oldest ts))
          (oset room oldest maybe-oldest))
      (oset room oldest maybe-oldest))))

(defmethod slack-room-push-message ((room slack-room) message)
  (with-slots (messages) room
    (slack-room-set-oldest room (list message))
    (setq messages
          (cl-remove-if #'(lambda (n) (slack-message-equal message n))
                        messages))
    (push message messages)))

(defmethod slack-room-set-messages ((room slack-room) messages)
  (let ((sorted (slack-room-sort-messages
                 (slack-room-gather-thread-messages messages))))
    (oset room oldest (car sorted))
    (oset room messages sorted)
    (oset room latest (car (last sorted)))))

(defmethod slack-room-prev-messages ((room slack-room) from)
  (with-slots (messages) room
    (cl-remove-if #'(lambda (m)
                      (or (string< from (oref m ts))
                          (string= from (oref m ts))))
                  (slack-room-sort-messages (copy-sequence messages)))))

(defmethod slack-room-update-mark ((room slack-room) team msg)
  (if (slack-room-update-last-read-p room (oref msg ts))
      (cl-labels ((on-update-mark (&key data &allow-other-keys)
                                  (slack-request-handle-error
                                   (data "slack-room-update-mark"))))
        (with-slots (ts) msg
          (with-slots (id) room
            (slack-request
             (slack-room-update-mark-url room)
             team
             :type "POST"
             :params (list (cons "channel"  id)
                           (cons "ts"  ts))
             :success #'on-update-mark
             :sync nil))))))

(defun slack-room-pins-list ()
  (interactive)
  (unless (and (bound-and-true-p slack-current-room-id)
               (bound-and-true-p slack-current-team-id))
    (error "Call from slack room buffer"))
  (let* ((team (slack-team-find slack-current-team-id))
         (room (slack-room-find slack-current-room-id
                                team))
         (channel (oref room id)))
    (cl-labels ((on-pins-list (&key data &allow-other-keys)
                              (slack-request-handle-error
                               (data "slack-room-pins-list")
                               (slack-room-on-pins-list
                                (plist-get data :items)
                                room team))))
      (slack-request
       slack-room-pins-list-url
       team
       :params (list (cons "channel" channel))
       :success #'on-pins-list
       :sync nil))))

(defun slack-room-on-pins-list (items room team)
  (cl-labels ((buffer-name (room)
                           (concat "*Slack - Pinned Items*"
                                   " : "
                                   (slack-room-display-name room))))
    (let* ((messages (mapcar #'(lambda (m) (slack-message-create m team :room room))
                             (mapcar #'(lambda (i)
                                         (plist-get i :message))
                                     items)))
           (buf-header (propertize "Pinned Items"
                                   'face '(:underline
                                           t
                                           :weight bold))))
      (funcall slack-buffer-function
               (slack-buffer-create-info
                (buffer-name room)
                #'(lambda ()
                    (insert buf-header)
                    (insert "\n\n")
                    (mapc #'(lambda (m) (insert
                                         (slack-message-to-string m)))
                          messages)))
               team))))

(defun slack-select-rooms ()
  (interactive)
  (let ((team (slack-team-select)))
    (slack-room-select
     (cl-loop for team in (list team)
              append (with-slots (groups ims channels) team
                       (append ims groups channels))))))

(defun slack-create-room (url team success)
  (slack-request
   url
   team
   :type "POST"
   :params (list (cons "name" (read-from-minibuffer "Name: ")))
   :success success
   :sync nil))

(defun slack-room-rename (url room-alist-func)
  (cl-labels
      ((on-rename-success (&key data &allow-other-keys)
                          (slack-request-handle-error
                           (data "slack-room-rename"))))
    (let* ((team (slack-team-select))
           (room-alist (funcall room-alist-func team))
           (room (slack-select-from-list
                  (room-alist "Select Channel: ")))
           (name (read-from-minibuffer "New Name: ")))
      (slack-request
       url
       team
       :params (list (cons "channel" (oref room id))
                     (cons "name" name))
       :success #'on-rename-success
       :sync nil))))

(defmacro slack-current-room-or-select (room-alist-func)
  `(if (and (boundp 'slack-current-room-id)
            (boundp 'slack-current-team-id))
       (slack-room-find slack-current-room-id
                        (slack-team-find slack-current-team-id))
     (let* ((room-alist (funcall ,room-alist-func)))
       (slack-select-from-list
        (room-alist "Select Channel: ")))))

(defmacro slack-room-invite (url room-alist-func)
  `(cl-labels
       ((on-group-invite (&key data &allow-other-keys)
                         (slack-request-handle-error
                          (data "slack-room-invite")
                          (if (plist-get data :already_in_group)
                              (message "User already in group")
                            (message "Invited!")))))
     (let* ((team (slack-team-select))
            (room (slack-current-room-or-select
                   #'(lambda ()
                       (funcall ,room-alist-func team
                                #'(lambda (rooms)
                                    (cl-remove-if #'slack-room-archived-p
                                                  rooms))))))
            (user-id (plist-get (slack-select-from-list
                                 ((slack-user-names team)
                                  "Select User: ")) :id)))
       (slack-request
        ,url
        team
        :params (list (cons "channel" (oref room id))
                      (cons "user" user-id))
        :success #'on-group-invite
        :sync nil))))

(defmethod slack-room-member-p ((_room slack-room)) t)

(defmethod slack-room-archived-p ((_room slack-room)) nil)

(defmethod slack-room-open-p ((_room slack-room)) t)

(defmethod slack-room-equal-p ((room slack-room) other)
  (string= (oref room id) (oref other id)))

(defun slack-room-deleted (id team)
  (let ((room (slack-room-find id team)))
    (cond
     ((object-of-class-p room 'slack-channel)
      (with-slots (channels) team
        (setq channels (cl-delete-if #'(lambda (c) (slack-room-equal-p room c))
                                     channels)))
      (message "Channel: %s deleted"
               (slack-room-display-name room))))))

(cl-defun slack-room-request-with-id (url id team success)
  (slack-request
   url
   team
   :params (list (cons "channel" id))
   :success success
   :sync nil))

(defmethod slack-room-reset-last-read ((room slack-room))
  (oset room last-read "0"))

(defmethod slack-room-inc-unread-count ((room slack-room))
  (cl-incf (oref room unread-count-display)))

(defun slack-room-find-by-name (name team)
  (cl-labels
      ((find-by-name (rooms name)
                     (cl-find-if #'(lambda (e) (string= name
                                                        (slack-room-name e)))
                                 rooms)))
    (or (find-by-name (oref team groups) name)
        (find-by-name (oref team channels) name)
        (find-by-name (oref team ims) name))))

(defmethod slack-room-setup-buffer ((room slack-room) buf)
  (with-current-buffer buf
    (slack-mode)
    (slack-room-insert-previous-link room buf)
    (goto-char lui-input-marker)
    (add-hook 'kill-buffer-hook 'slack-reset-room-last-read nil t)
    (add-hook 'lui-pre-output-hook 'slack-buffer-buttonize-link nil t)))

(defmethod slack-room-insert-messages ((room slack-room) buf team)
  (let* ((sorted (slack-room-sorted-messages room))
         (thread-rejected (slack-room-reject-thread-message sorted))
         (messages (slack-room-latest-messages room thread-rejected))
         (latest-message (and (car (last sorted)))))
    (if messages
        (progn
          (with-current-buffer buf
            (cl-loop for m in messages
                     do (slack-buffer-insert m team t)))
          (slack-room-update-last-read room latest-message)
          (slack-room-update-mark room team latest-message))
      (unless (eq 0 (oref room unread-count-display))
        (slack-room-update-mark room team latest-message)))))


(provide 'slack-room)
;;; slack-room.el ends here
