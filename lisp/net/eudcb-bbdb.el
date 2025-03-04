;;; eudcb-bbdb.el --- Emacs Unified Directory Client - BBDB Backend  -*- lexical-binding: t; -*-

;; Copyright (C) 1998-2025 Free Software Foundation, Inc.

;; Author: Oscar Figueiredo <oscar@cpe.fr>
;;         Pavel Janík <Pavel@Janik.cz>
;; Maintainer: Thomas Fitzsimmons <fitzsim@fitzsim.org>
;; Keywords: comm
;; Package: eudc

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;    This library provides an interface to use BBDB as a backend of
;;    the Emacs Unified Directory Client.

;;; Code:

(require 'eudc)

;; Make it loadable on systems without bbdb.
(require 'bbdb nil t)
(require 'bbdb-com nil t)
(require 'seq)

;;{{{      Internal cooking

;; I don't like this but mapcar does not accept a parameter to the function and
;; I don't want to use mapcar*
(defvar eudc-bbdb-current-query nil)
(defvar eudc-bbdb-current-return-attributes nil)

(defun eudc-bbdb-field (field-symbol)
  "Convert FIELD-SYMBOL so that it is recognized by the current BBDB version.
BBDB < 3 used `net'; BBDB >= 3 uses `mail'."
  ;; This just-in-time translation permits upgrading from BBDB 2 to
  ;; BBDB 3 without restarting Emacs.
  (cond ((and (eq field-symbol 'net)
	      (eudc--using-bbdb-3-or-newer-p))
         'mail)
        ((and (eq field-symbol 'company)
	      (eudc--using-bbdb-3-or-newer-p))
         'organization)
        (t field-symbol)))

(defvar eudc-bbdb-attributes-translation-alist
  '((name . lastname)
    (email . net)
    (phone . phones))
  "Alist mapping EUDC attribute names to BBDB names.")

(eudc-protocol-set 'eudc-query-function 'eudc-bbdb-query-internal 'bbdb)
(eudc-protocol-set 'eudc-list-attributes-function nil 'bbdb)
(eudc-protocol-set 'eudc-protocol-attributes-translation-alist
		   'eudc-bbdb-attributes-translation-alist 'bbdb)
(eudc-protocol-set 'eudc-bbdb-conversion-alist nil 'bbdb)
(eudc-protocol-set 'eudc-protocol-has-default-query-attributes nil 'bbdb)

(defun eudc-bbdb-format-query (query)
  "Format a EUDC query alist into a list suitable to `bbdb-search'."
  (let* ((firstname (cdr (assq 'firstname query)))
	 (lastname (cdr (assq 'lastname query)))
	 (name (or (and firstname lastname
			(concat firstname " " lastname))
		   firstname
		   lastname))
	(company (cdr (assq 'company query)))
	(net (cdr (assq 'net query)))
	(notes (cdr (assq 'notes query)))
	(phone (cdr (assq 'phone query))))
    (list name company net notes phone)))


(defun eudc-bbdb-filter-non-matching-record (record)
  "Return RECORD if it matches `eudc-bbdb-current-query', nil otherwise."
  (require 'bbdb)
  (catch 'unmatch
    (dolist (condition eudc-bbdb-current-query)
      (let ((attr (car condition))
            (val (cdr condition))
            (case-fold-search t))
        (or (and (memq attr '(firstname lastname aka company phones
                              addresses net))
                 (let ((bbdb-val
                        (funcall (intern (concat "bbdb-record-"
                                                 (symbol-name
                                                  (eudc-bbdb-field
                                                   attr))))
                                 record)))
                   (if (listp bbdb-val)
                       (if eudc-bbdb-enable-substring-matches
                           (seq-some (lambda (subval)
                                       (string-match val subval))
                                     bbdb-val)
                         (member (downcase val)
                                 (mapcar #'downcase bbdb-val)))
                     (if eudc-bbdb-enable-substring-matches
                         (string-match val bbdb-val)
                       (string-equal (downcase val) (downcase bbdb-val))))))
            (throw 'unmatch nil))))
    record))

;; External.
(declare-function bbdb-phone-location   "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-phone-string     "ext:bbdb" (phone))
(declare-function bbdb-record-phones    "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-address-streets  "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-address-city     "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-address-state    "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-address-zip      "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-address-location "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-record-addresses "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-records          "ext:bbdb"
                  (&optional dont-check-disk already-in-db-buffer))
(declare-function bbdb-record-notes "ext:bbdb" t) ; via bbdb-defstruct

;; External, BBDB >= 3.
(declare-function bbdb-phone-label "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-record-phone "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-record-address "ext:bbdb" t) ; via bbdb-defstruct
(declare-function bbdb-record-xfield "ext:bbdb" t) ; via bbdb-defstruct

(defun eudc-bbdb-extract-phones (record)
  (require 'bbdb)
  (mapcar (lambda (phone)
            (if eudc-bbdb-use-locations-as-attribute-names
                (cons (intern (if (eudc--using-bbdb-3-or-newer-p)
                                  (bbdb-phone-label phone)
                                (bbdb-phone-location phone)))
                      (bbdb-phone-string phone))
              (cons 'phones (format "%s: %s"
                                    (if (eudc--using-bbdb-3-or-newer-p)
                                        (bbdb-phone-label phone)
                                      (bbdb-phone-location phone))
                                    (bbdb-phone-string phone)))))
	  (if (eudc--using-bbdb-3-or-newer-p)
              (bbdb-record-phone record)
            (bbdb-record-phones record))))

(defun eudc-bbdb-extract-addresses (record)
  (require 'bbdb)
  (let (s c val)
    (mapcar (lambda (address)
              (setq c (bbdb-address-streets address))
              (dotimes (n 3)
                (unless (zerop (length (setq s (nth n c))))
                  (setq val (concat val s "\n"))))
              (setq c (bbdb-address-city address)
                    s (bbdb-address-state address))
              (setq val (concat val
                                (if (and (> (length c) 0) (> (length s) 0))
                                    (concat c ", " s)
                                  c)
                                " "
                                (bbdb-address-zip address)))
              (if eudc-bbdb-use-locations-as-attribute-names
                  (cons (intern (bbdb-address-location address)) val)
                (cons 'addresses (concat (bbdb-address-location address)
                                         "\n" val))))
            (if (eudc--using-bbdb-3-or-newer-p)
                (bbdb-record-address record)
              (bbdb-record-addresses record)))))

(defun eudc-bbdb-format-record-as-result (record)
  "Format the BBDB RECORD as a EUDC query result record.
The record is filtered according to `eudc-bbdb-current-return-attributes'."
  (require 'bbdb)
  (let ((attrs (or eudc-bbdb-current-return-attributes
		   '(firstname lastname aka company phones addresses net notes)))
	eudc-rec)
    (dolist (attr attrs)
      (let ((val
             (pcase attr
              ('phones    (eudc-bbdb-extract-phones record))
	      ('addresses (eudc-bbdb-extract-addresses record))
	      ('notes
               (if (eudc--using-bbdb-3-or-newer-p)
                   (bbdb-record-xfield record 'notes)
                 (bbdb-record-notes record)))
              ((or 'firstname 'lastname 'aka 'company 'net)
               (funcall (intern
			 (concat "bbdb-record-"
				 (symbol-name (eudc-bbdb-field attr))))
			record))
	      (_
	       (error "Unknown BBDB attribute")))))
	(cond
	 ((or (not val) (equal val ""))) ; do nothing
	 ((memq attr '(phones addresses))
	  (setq eudc-rec (append val eudc-rec)))
	 ((and (listp val)
	       (= 1 (length val)))
	  (push (cons attr (car val)) eudc-rec))
	 ((> (length val) 0)
	  (push (cons attr val) eudc-rec))
	 (t
	  (error "Unexpected attribute value")))))
    (nreverse eudc-rec)))



(defun eudc-bbdb-query-internal (query &optional return-attrs)
  "Query BBDB  with QUERY.
QUERY is a list of cons cells (ATTR . VALUE) where ATTRs should be valid
BBDB attribute names.
RETURN-ATTRS is a list of attributes to return, defaulting to
`eudc-default-return-attributes'."
  (require 'bbdb)
  (let ((eudc-bbdb-current-query query)
	(eudc-bbdb-current-return-attributes return-attrs)
	(query-attrs (eudc-bbdb-format-query query))
	bbdb-attrs
	(records (bbdb-records))
	result
	filtered)
    ;; BBDB ORs its query attributes while EUDC ANDs them, hence we need to
    ;; call bbdb-search iteratively on the returned records for each of the
    ;; requested attributes
    (while (and records (> (length query-attrs) 0))
      (setq bbdb-attrs (append bbdb-attrs (list (car query-attrs))))
      (if (car query-attrs)
	  ;; BEWARE: `bbdb-search' is a macro!
	  (setq records (eval `(bbdb-search (quote ,records) ,@bbdb-attrs) t)))
      (setq query-attrs (cdr query-attrs)))
    (mapc (lambda (record)
            (setq filtered (eudc-filter-duplicate-attributes record))
            ;; If there were duplicate attributes reverse the order of the
            ;; record so the unique attributes appear first
            (if (> (length filtered) 1)
                (setq filtered (mapcar #'reverse filtered)))
            (setq result (append result filtered)))
	  (delq nil
		(mapcar #'eudc-bbdb-format-record-as-result
			(delq nil
			      (mapcar #'eudc-bbdb-filter-non-matching-record
				      records)))))
    result))

;;}}}

;;{{{      High-level interfaces (interactive functions)

(defun eudc-bbdb-set-server (dummy)
  "Set the EUDC server to BBDB."
  (interactive)
  (eudc-set-server dummy 'bbdb)
  (message "BBDB server selected"))

;;}}}


(eudc-register-protocol 'bbdb)

(provide 'eudcb-bbdb)

;;; eudcb-bbdb.el ends here
