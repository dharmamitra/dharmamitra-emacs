;;; dharmamitra.el --- Sanskrit/Pāli/Tibetan/Chinese analysis via dharmamitra.org -*- lexical-binding: t -*-

;; Author: Sebastian Nehrdich
;; Assisted-by: Claude Code:claude-fable-5-1
;; URL: https://github.com/dharmamitra/dharmamitra-emacs
;; Keywords: languages, tools
;; Version: 0.2
;; Package-Requires: ((emacs "26.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Provides translation and grammar analysis for Sanskrit/Pāli/Tibetan/Chinese
;; texts using the public dharmamitra.org API.  No API key is required.
;;
;; Two endpoints are used:
;;   - Grammar:     POST /api-tagging/tagging-parsed/
;;   - Translation: POST /api-search/cat-translate/v1/translate
;;
;; Both requests are sent asynchronously through curl and rendered into the
;; `*Dharmamitra*' buffer as they arrive.  The buffer uses
;; `dharmamitra-text-mode', which offers keys to re-run the analysis, toggle
;; translation, expand full dictionary entries, move between words, switch
;; languages and copy results.  See `dharmamitra-text-mode' for the bindings.
;;
;; The package does not bind any global keys.  A typical setup is:
;;
;;   (require 'dharmamitra)
;;   (global-set-key (kbd "C-c g") #'dharmamitra-text-analyze-grammar)
;;   (global-set-key (kbd "C-c t") #'dharmamitra-text-translate)

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)

(defgroup dharmamitra nil
  "Translation and grammar analysis using the dharmamitra.org API."
  :group 'applications
  :prefix "dharmamitra-text-")

(defcustom dharmamitra-text-include-translation t
  "Whether to include translations in the analysis output.
Disabling translations makes the analysis noticeably faster."
  :type 'boolean
  :group 'dharmamitra)

(defcustom dharmamitra-text-target-language "english"
  "Target language for translations, as accepted by the cat-translate API.
See `dharmamitra-text-target-languages' for known values."
  :type 'string
  :group 'dharmamitra)

(defcustom dharmamitra-text-source-language 'auto
  "Source language of the text sent for translation.
With `auto', Tibetan and Chinese script are detected automatically and
everything else is treated as Sanskrit.  Set this to `pali' when working
with Pāli text, since Pāli and Sanskrit in Latin script cannot be told
apart reliably."
  :type '(choice (const :tag "Detect (Latin script defaults to Sanskrit)" auto)
                 (const sanskrit)
                 (const pali)
                 (const tibetan)
                 (const chinese))
  :group 'dharmamitra)

(defcustom dharmamitra-text-translation-style "balanced"
  "Free-text style instruction passed to the translation API."
  :type 'string
  :group 'dharmamitra)

(defcustom dharmamitra-text-grammar-type "western"
  "Terminology used for grammatical tags: \"western\" or \"indic\"."
  :type '(choice (const "western") (const "indic"))
  :group 'dharmamitra)

(defcustom dharmamitra-text-meaning-max-length 160
  "Maximum number of characters shown per collapsed dictionary gloss."
  :type 'integer
  :group 'dharmamitra)

(defcustom dharmamitra-text-entry-max-length 4000
  "Maximum number of characters shown per expanded dictionary entry."
  :type 'integer
  :group 'dharmamitra)

(defcustom dharmamitra-text-tagging-url
  "https://dharmamitra.org/api-tagging/tagging-parsed/"
  "URL of the grammar (tagging) endpoint."
  :type 'string
  :group 'dharmamitra)

(defcustom dharmamitra-text-translation-url
  "https://dharmamitra.org/api-search/cat-translate/v1/translate"
  "URL of the translation endpoint."
  :type 'string
  :group 'dharmamitra)

(defcustom dharmamitra-text-curl-program "curl"
  "Name or path of the curl executable."
  :type 'string
  :group 'dharmamitra)

(defcustom dharmamitra-text-request-timeout 120
  "Maximum number of seconds to wait for an API response."
  :type 'integer
  :group 'dharmamitra)

(defcustom dharmamitra-text-display-action '(display-buffer-at-bottom)
  "Display action used to show the analysis buffer, see `display-buffer'."
  :type 'sexp
  :group 'dharmamitra)

(defconst dharmamitra-text-target-languages
  '("english" "german" "french" "italian" "spanish" "portuguese" "dutch"
    "russian" "hindi" "japanese" "korean" "vietnamese" "tibetan"
    "modern-chinese-simplified" "modern-chinese-traditional")
  "Target languages known to the translation API.")

(defface dharmamitra-text-word-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for word forms in Dharmamitra text analysis.")

(defface dharmamitra-text-lemma-face
  '((t :inherit font-lock-keyword-face))
  "Face for lemmas in Dharmamitra text analysis.")

(defface dharmamitra-text-grammar-face
  '((t :inherit font-lock-type-face))
  "Face for grammatical tags in Dharmamitra text analysis.")

(defface dharmamitra-text-meaning-face
  '((t :inherit font-lock-doc-face))
  "Face for meanings in Dharmamitra text analysis.")

(defface dharmamitra-text-source-face
  '((t :inherit font-lock-constant-face))
  "Face for dictionary source names in Dharmamitra text analysis.")

(defface dharmamitra-text-header-face
  '((t :inherit font-lock-comment-face :slant normal))
  "Face for category headers in Dharmamitra text analysis.")

(defface dharmamitra-text-error-face
  '((t :inherit error))
  "Face for error messages in Dharmamitra text analysis.")

(defvar dharmamitra-text-buffer-name "*Dharmamitra*"
  "Name of the buffer used to display analysis results.")

(defvar dharmamitra-text--request-counter 0
  "Counter used to ignore responses from superseded requests.")

(defvar-local dharmamitra-text--state nil
  "Plist holding the text and results of the analysis shown in this buffer.
Keys:
  :id          request identifier
  :text        the analyzed text
  :grammar     nil while pending, (:ok . SENTENCES), (:error . MESSAGE)
               or (:skipped . MESSAGE)
  :translation nil while pending, `disabled', (:ok . TEXT) or
               (:error . MESSAGE)
  :expanded    list of word keys (SENTENCE-INDEX * 10000 + WORD-INDEX)
               whose dictionary entries are expanded
  :expand-all  non-nil when every dictionary entry is expanded")

;;;; HTTP

(defun dharmamitra-text--post-json (url payload callback)
  "POST PAYLOAD (an alist) as JSON to URL asynchronously.
CALLBACK is called with three arguments: an error string or nil, the
HTTP status code (or nil) and the response body."
  (let* ((json (let ((json-encoding-pretty-print nil))
                 (json-encode payload)))
         (output (generate-new-buffer " *dharmamitra-http*"))
         (proc (make-process
                :name "dharmamitra-curl"
                :buffer output
                :command (list dharmamitra-text-curl-program
                               "-s" "-S" "-X" "POST"
                               "-H" "Content-Type: application/json"
                               "-H" "Accept: application/json"
                               "--max-time" (number-to-string dharmamitra-text-request-timeout)
                               "--data-binary" "@-"
                               "--write-out" "\n__DM_HTTP__%{http_code}"
                               url)
                :coding 'utf-8
                :connection-type 'pipe
                :noquery t
                :sentinel
                (lambda (p _event)
                  (when (memq (process-status p) '(exit signal))
                    (let ((raw (with-current-buffer (process-buffer p)
                                 (buffer-string)))
                          (code (process-exit-status p)))
                      (kill-buffer (process-buffer p))
                      (cond
                       ((/= code 0)
                        (funcall callback
                                 (format "curl failed (exit %d): %s"
                                         code
                                         (string-trim
                                          (replace-regexp-in-string
                                           "\n__DM_HTTP__[0-9]*\\'" "" raw)))
                                 nil nil))
                       ((string-match "\n__DM_HTTP__\\([0-9]+\\)\\'" raw)
                        (funcall callback nil
                                 (string-to-number (match-string 1 raw))
                                 (substring raw 0 (match-beginning 0))))
                       (t (funcall callback nil nil raw)))))))))
    (process-send-string proc json)
    (process-send-eof proc)
    proc))

(defun dharmamitra-text--parse-json (body)
  "Parse BODY as JSON into alists and lists, or return nil on failure."
  (condition-case nil
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-key-type 'symbol)
            (json-false nil)
            (json-null nil))
        (json-read-from-string body))
    (error nil)))

(defun dharmamitra-text--truncate (string length)
  "Return STRING on one line, shortened to LENGTH characters with an ellipsis."
  (let ((s (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " string))))
    (if (> (length s) length)
        (concat (substring s 0 length) "…")
      s)))

(defun dharmamitra-text--detail-string (detail)
  "Render a FastAPI error DETAIL (string or list of validation errors)."
  (cond
   ((stringp detail) detail)
   ((and (listp detail) (consp (car-safe detail)))
    (mapconcat (lambda (item)
                 (let ((msg (alist-get 'msg item))
                       (loc (alist-get 'loc item)))
                   (if loc
                       (format "%s (%s)" msg (mapconcat (lambda (x) (format "%s" x)) loc "."))
                     (format "%s" msg))))
               detail "; "))
   (t (format "%s" detail))))

(defun dharmamitra-text--response-error (http body data)
  "Return an error message for a failed response, or nil when it is fine.
HTTP is the status code, BODY the raw body and DATA the parsed JSON."
  (cond
   ((and (consp data) (assq 'detail data))
    (dharmamitra-text--detail-string (alist-get 'detail data)))
   ((and http (not (<= 200 http 299)))
    (format "HTTP %d: %s" http (dharmamitra-text--truncate body 200)))
   ((null data)
    (format "Unexpected response: %s" (dharmamitra-text--truncate body 200)))))

;;;; Language detection

(defun dharmamitra-text-detect-language (text)
  "Guess the source language of TEXT from its script.
Returns `tibetan', `chinese' or `sanskrit'."
  (cond
   ((string-match-p "[ༀ-࿿]" text) 'tibetan)
   ((string-match-p "[㐀-䶿一-鿿豈-﫿]" text) 'chinese)
   (t 'sanskrit)))

(defun dharmamitra-text--source-language (text)
  "Return the effective source language symbol for TEXT."
  (if (eq dharmamitra-text-source-language 'auto)
      (dharmamitra-text-detect-language text)
    dharmamitra-text-source-language))

(defun dharmamitra-text--language-code (language)
  "Return a short code for LANGUAGE for display purposes."
  (pcase language
    ('tibetan "bo")
    ('chinese "zh")
    ('pali "pa")
    (_ "sa")))

;;;; Grammar

(defun dharmamitra-text--tagging-payload (text)
  "Build the request body for the tagging API from TEXT."
  `(("texts" . ,(vconcat (split-string text "\n" t "[ \t\r]+")))
    ("mode" . "unsandhied-lemma-morphosyntax")
    ("human_readable_tags" . t)
    ("grammar_type" . ,dharmamitra-text-grammar-type)))

(defun dharmamitra-text--parse-grammar (err http body)
  "Turn a tagging response into (:ok . SENTENCES) or (:error . MESSAGE).
ERR is a transport error string or nil, HTTP the status code and BODY
the response body."
  (if err
      (cons :error err)
    (let* ((data (dharmamitra-text--parse-json body))
           (problem (dharmamitra-text--response-error http body data)))
      (cond
       (problem (cons :error problem))
       ((and (listp data) data
             (consp (car data))
             (assq 'grammatical_analysis (car data)))
        (if (seq-some (lambda (s) (alist-get 'grammatical_analysis s)) data)
            (cons :ok data)
          (cons :error "the parser returned no analysis for this input")))
       (t (cons :error (format "Unexpected response: %s"
                               (dharmamitra-text--truncate body 200))))))))

(defun dharmamitra-text--strip-markdown (string)
  "Remove the light markdown used in dictionary entries from STRING."
  (let ((s string))
    (setq s (replace-regexp-in-string "\\[\\([^]]*\\)\\]([^)]*)" "\\1" s))
    (setq s (replace-regexp-in-string "\\*\\*\\|__" "" s))
    (setq s (replace-regexp-in-string "[*`]" "" s))
    (setq s (replace-regexp-in-string "[ \t]+" " " s))
    (string-trim s)))

(defun dharmamitra-text--entry-lines (meaning)
  "Return the content lines of MEANING without headings and page links."
  (seq-remove
   (lambda (line)
     (or (string-prefix-p "#" line)
         (string-prefix-p "---" line)
         (string-prefix-p "**Page:**" line)
         (string-prefix-p "[Open PDF" line)))
   (split-string (or (alist-get 'meaning meaning) "") "\n" t "[ \t\r]+")))

(defun dharmamitra-text--meaning-gloss (meaning)
  "Return a one-line gloss for MEANING, an alist with `meaning' and `source'."
  (let ((lines (dharmamitra-text--entry-lines meaning))
        (acc ""))
    (while (and lines (< (length acc) dharmamitra-text-meaning-max-length))
      (setq acc (concat acc (if (string-empty-p acc) "" " ") (pop lines))))
    (dharmamitra-text--truncate (dharmamitra-text--strip-markdown acc)
                                dharmamitra-text-meaning-max-length)))

(defun dharmamitra-text--meaning-entry (meaning)
  "Return the full text of MEANING, wrapped and limited in length."
  (let* ((text (mapconcat #'dharmamitra-text--strip-markdown
                          (dharmamitra-text--entry-lines meaning)
                          "\n"))
         (truncated (> (length text) dharmamitra-text-entry-max-length))
         (text (if truncated
                   (substring text 0 dharmamitra-text-entry-max-length)
                 text)))
    (with-temp-buffer
      (insert text)
      (let ((fill-column (max 40 (- (or (and (get-buffer-window dharmamitra-text-buffer-name)
                                              (window-width (get-buffer-window dharmamitra-text-buffer-name)))
                                         fill-column)
                                     6))))
        (fill-region (point-min) (point-max)))
      (concat (buffer-string)
              (if truncated "\n[entry truncated, follow the source link for the full text]" "")))))

(defun dharmamitra-text--source-label (meaning)
  "Return the source name of MEANING, as a link when a page link exists."
  (let ((source (or (alist-get 'source meaning) "Dictionary"))
        (link (alist-get 'page_link meaning)))
    (if (and (stringp link) (not (string-empty-p link)))
        (make-text-button (copy-sequence source) nil
                          'face 'dharmamitra-text-source-face
                          'follow-link t
                          'help-echo (concat "mouse-1, RET: open " link)
                          'action (lambda (_button) (browse-url link)))
      (propertize source 'face 'dharmamitra-text-source-face))))

(defun dharmamitra-text--sorted-meanings (meanings)
  "Return MEANINGS with the concise DCS glosses first."
  (append (seq-filter (lambda (m) (equal (alist-get 'source m) "DCS")) meanings)
          (seq-remove (lambda (m) (equal (alist-get 'source m) "DCS")) meanings)))

(defun dharmamitra-text--indent (text prefix)
  "Prefix every line of TEXT with PREFIX."
  (mapconcat (lambda (line) (concat prefix line))
             (split-string text "\n")
             "\n"))

(defun dharmamitra-text--format-word (item key expanded)
  "Format one word ITEM of the analysis.
KEY is the integer SENTENCE-INDEX * 10000 + WORD-INDEX and EXPANDED
says whether full dictionary entries should be shown."
  (let* ((lemma (or (cdr (assoc 'lemma item)) ""))
         (unsandhied (or (cdr (assoc 'unsandhied item)) ""))
         (tag (or (cdr (assoc 'tag item)) ""))
         (meanings (dharmamitra-text--sorted-meanings (cdr (assoc 'meanings item))))
         (summary (format "%s [%s] %s" unsandhied lemma tag))
         (block
          (concat
           (propertize "╭─ " 'dharmamitra-word-start t)
           (propertize unsandhied 'face 'dharmamitra-text-word-face)
           " ["
           (propertize lemma 'face 'dharmamitra-text-lemma-face)
           "]"
           (if (and meanings (not expanded))
               (dharmamitra-text--header "  [TAB: dictionary]")
             "")
           "\n│  "
           (propertize tag 'face 'dharmamitra-text-grammar-face)
           "\n"
           (mapconcat
            (lambda (meaning)
              (let ((gloss (dharmamitra-text--meaning-gloss meaning)))
                (concat "│  → "
                        (dharmamitra-text--source-label meaning)
                        (if (string-empty-p gloss) "" ": ")
                        (propertize gloss 'face 'dharmamitra-text-meaning-face)
                        "\n"
                        (if expanded
                            (concat
                             (dharmamitra-text--indent
                              (propertize (dharmamitra-text--meaning-entry meaning)
                                          'face 'dharmamitra-text-meaning-face)
                              "│     ")
                             "\n")
                          ""))))
            meanings
            "")
           "╰────\n")))
    (propertize block 'dharmamitra-word key 'dharmamitra-copy summary)))

(defun dharmamitra-text--format-sentence (sentence index state)
  "Format the analysis of SENTENCE number INDEX according to STATE."
  (let ((expand-all (plist-get state :expand-all))
        (expanded (plist-get state :expanded))
        (word-index -1))
    (mapconcat
     (lambda (item)
       (setq word-index (1+ word-index))
       (let ((key (+ (* index 10000) word-index)))
         (dharmamitra-text--format-word
          item key (or expand-all (memq key expanded)))))
     (cdr (assoc 'grammatical_analysis sentence))
     "")))

(defun dharmamitra-text-join-unsandhied (words)
  "Join unsandhied WORDS, omitting spaces after hyphens."
  (let ((result "")
        (prev-ended-with-hyphen nil))
    (dolist (word words)
      (if prev-ended-with-hyphen
          (setq result (concat result word))
        (unless (string= result "")
          (setq result (concat result " ")))
        (setq result (concat result word)))
      (setq prev-ended-with-hyphen (string-match-p "-$" word)))
    result))

(defun dharmamitra-text-get-forms (sentences)
  "Extract joined unsandhied and lemma forms from the parsed SENTENCES."
  (let ((unsandhied-forms '())
        (lemma-forms '()))
    (dolist (sentence sentences)
      (dolist (item (cdr (assoc 'grammatical_analysis sentence)))
        (push (or (cdr (assoc 'unsandhied item)) "") unsandhied-forms)
        (push (or (cdr (assoc 'lemma item)) "") lemma-forms)))
    (list (dharmamitra-text-join-unsandhied (reverse unsandhied-forms))
          (mapconcat #'identity (reverse lemma-forms) " "))))

;;;; Translation

(defun dharmamitra-text--translation-payload (text)
  "Build the request body for the cat-translate API from TEXT."
  (let ((field (pcase (dharmamitra-text--source-language text)
                 ('tibetan "input_tibetan")
                 ('chinese "input_chinese")
                 ('pali "input_pali")
                 (_ "input_sanskrit"))))
    `((,field . ,text)
      ("target_language" . ,dharmamitra-text-target-language)
      ("style_instruction" . ,dharmamitra-text-translation-style)
      ("focus" . "equal"))))

(defun dharmamitra-text-clean-response (response)
  "Normalise whitespace in the translation RESPONSE."
  (let ((text response))
    (setq text (replace-regexp-in-string "\r" "" text t t))
    (setq text (replace-regexp-in-string "🔽" "\n" text t t))
    (setq text (replace-regexp-in-string "[ \t]+" " " text t t))
    (setq text (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text t t))
    (string-trim text)))

(defun dharmamitra-text--parse-translation (err http body)
  "Turn a translation response into (:ok . TEXT) or (:error . MESSAGE).
ERR is a transport error string or nil, HTTP the status code and BODY
the response body."
  (if err
      (cons :error err)
    (let* ((data (dharmamitra-text--parse-json body))
           (problem (dharmamitra-text--response-error http body data))
           (translation (and (consp data) (alist-get 'translation data))))
      (cond
       (problem (cons :error problem))
       ((stringp translation)
        (cons :ok (dharmamitra-text-clean-response translation)))
       (t (cons :error (format "Unexpected response: %s"
                               (dharmamitra-text--truncate body 200))))))))

;;;; Rendering

(defun dharmamitra-text--header (string)
  "Propertize STRING with the header face."
  (propertize string 'face 'dharmamitra-text-header-face))

(defun dharmamitra-text--field (label value face copy)
  "Return a result line with LABEL and VALUE shown in FACE.
COPY is the plain text stored for `dharmamitra-text-copy'."
  (propertize (concat (dharmamitra-text--header (format "%-12s ⟦ " label))
                      (propertize value 'face face)
                      (dharmamitra-text--header " ⟧\n"))
              'dharmamitra-copy copy))

(defun dharmamitra-text--status-line (label message &optional error)
  "Return a status line with LABEL and MESSAGE, styled as an ERROR if non-nil."
  (concat (dharmamitra-text--header (format "%-12s " label))
          (if error
              (propertize message 'face 'dharmamitra-text-error-face)
            (dharmamitra-text--header message))
          "\n"))

(defun dharmamitra-text--render (buffer)
  "Redraw the analysis BUFFER from its current state, keeping point's line."
  (with-current-buffer buffer
    (let* ((state dharmamitra-text--state)
           (text (plist-get state :text))
           (grammar (plist-get state :grammar))
           (translation (plist-get state :translation))
           (line (line-number-at-pos))
           (inhibit-read-only t))
      (erase-buffer)
      (remove-overlays)
      (insert (dharmamitra-text--field "Original:" text 'dharmamitra-text-word-face text))
      (pcase grammar
        ('nil
         (insert (dharmamitra-text--status-line "Grammar:" "analyzing…")))
        (`(:skipped . ,message)
         (insert (dharmamitra-text--status-line "Grammar:" message)))
        (`(:error . ,message)
         (insert (dharmamitra-text--status-line
                  "Grammar:" (concat "analysis unsuccessful: " message) t)))
        (`(:ok . ,sentences)
         (let ((forms (dharmamitra-text-get-forms sentences)))
           (insert (dharmamitra-text--field "Segmented:" (car forms)
                                            'dharmamitra-text-word-face (car forms))
                   (dharmamitra-text--field "Lemmatized:" (cadr forms)
                                            'dharmamitra-text-lemma-face (cadr forms))))))
      (pcase translation
        ('disabled
         (insert (dharmamitra-text--status-line "Translation:" "disabled (t to enable)")))
        ('nil
         (insert (dharmamitra-text--status-line "Translation:" "translating…")))
        (`(:error . ,message)
         (insert (dharmamitra-text--status-line
                  "Translation:" (concat "unsuccessful: " message) t)))
        (`(:ok . ,result)
         (insert (dharmamitra-text--field "Translation:" result
                                          'dharmamitra-text-meaning-face result))))
      (when (eq (car-safe grammar) :ok)
        (let* ((sentences (cdr grammar))
               (multiple (> (length sentences) 1))
               (index -1))
          (insert "\n")
          (dolist (sentence sentences)
            (setq index (1+ index))
            (when multiple
              (insert (dharmamitra-text--header
                       (format "── %s\n" (or (alist-get 'sentence sentence) "")))))
            (let ((notice (alist-get 'notice sentence)))
              (when (and (stringp notice) (not (string-empty-p notice)))
                (insert (dharmamitra-text--header (format "   %s\n" notice)))))
            (insert (dharmamitra-text--format-sentence sentence index state)))))
      (goto-char (point-min))
      (forward-line (1- line))
      (dharmamitra-text--update-mode-line))))

(defun dharmamitra-text--update-mode-line ()
  "Show the language pair in the mode line of the analysis buffer."
  (let ((text (plist-get dharmamitra-text--state :text)))
    (setq mode-name
          (format "Dharmamitra[%s→%s]"
                  (if text (dharmamitra-text--language-code
                            (dharmamitra-text--source-language text))
                    "?")
                  dharmamitra-text-target-language))
    (force-mode-line-update)))

(defun dharmamitra-text--receive (buffer id key result)
  "Store RESULT under KEY in BUFFER if request ID is still current, then redraw."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eql (plist-get dharmamitra-text--state :id) id)
        (setq dharmamitra-text--state
              (plist-put dharmamitra-text--state key result))
        (dharmamitra-text--render buffer)))))

;;;; Major mode

(defvar dharmamitra-text-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'dharmamitra-text-rerun)
    (define-key map (kbd "t") #'dharmamitra-text-toggle-translation)
    (define-key map (kbd "TAB") #'dharmamitra-text-toggle-entry)
    (define-key map (kbd "<tab>") #'dharmamitra-text-toggle-entry)
    (define-key map (kbd "E") #'dharmamitra-text-toggle-all-entries)
    (define-key map (kbd "n") #'dharmamitra-text-next-word)
    (define-key map (kbd "p") #'dharmamitra-text-previous-word)
    (define-key map (kbd "l") #'dharmamitra-text-set-target-language)
    (define-key map (kbd "s") #'dharmamitra-text-set-source-language)
    (define-key map (kbd "w") #'dharmamitra-text-copy)
    map)
  "Keymap for `dharmamitra-text-mode'.")

(define-derived-mode dharmamitra-text-mode special-mode "Dharmamitra"
  "Major mode for the dharmamitra.org analysis buffer.

\\{dharmamitra-text-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq header-line-format
        (concat " "
                (dharmamitra-text--header
                 "g rerun  t translation  TAB dictionary  E all  n/p word  l target  s source  w copy  q quit"))))

(defun dharmamitra-text--check-buffer ()
  "Signal an error unless the current buffer is a Dharmamitra analysis."
  (unless (and (derived-mode-p 'dharmamitra-text-mode)
               (plist-get dharmamitra-text--state :text))
    (user-error "No Dharmamitra analysis in this buffer")))

(defun dharmamitra-text-rerun ()
  "Run the analysis of the current buffer's text again."
  (interactive)
  (dharmamitra-text--check-buffer)
  (dharmamitra-text--start (plist-get dharmamitra-text--state :text)))

(defun dharmamitra-text-toggle-translation ()
  "Toggle `dharmamitra-text-include-translation' and rerun the analysis."
  (interactive)
  (setq dharmamitra-text-include-translation
        (not dharmamitra-text-include-translation))
  (message "Dharmamitra translation %s"
           (if dharmamitra-text-include-translation "enabled" "disabled"))
  (when (and (derived-mode-p 'dharmamitra-text-mode)
             (plist-get dharmamitra-text--state :text))
    (dharmamitra-text-rerun)))

(defun dharmamitra-text--word-at-point ()
  "Return the integer key of the word block at point, or nil."
  (get-text-property (point) 'dharmamitra-word))

(defun dharmamitra-text-toggle-entry ()
  "Expand or collapse the full dictionary entries of the word at point."
  (interactive)
  (dharmamitra-text--check-buffer)
  (let ((key (dharmamitra-text--word-at-point)))
    (unless key
      (user-error "No word entry at point"))
    (let ((expanded (plist-get dharmamitra-text--state :expanded)))
      (setq dharmamitra-text--state
            (plist-put dharmamitra-text--state :expanded
                       (if (memq key expanded)
                           (delq key expanded)
                         (cons key expanded))))
      (setq dharmamitra-text--state
            (plist-put dharmamitra-text--state :expand-all nil))
      (dharmamitra-text--render (current-buffer))
      (dharmamitra-text--goto-word key))))

(defun dharmamitra-text-toggle-all-entries ()
  "Expand or collapse the full dictionary entries of every word."
  (interactive)
  (dharmamitra-text--check-buffer)
  (let ((key (dharmamitra-text--word-at-point)))
    (setq dharmamitra-text--state
          (plist-put dharmamitra-text--state :expand-all
                     (not (plist-get dharmamitra-text--state :expand-all))))
    (setq dharmamitra-text--state
          (plist-put dharmamitra-text--state :expanded nil))
    (dharmamitra-text--render (current-buffer))
    (when key (dharmamitra-text--goto-word key))))

(defun dharmamitra-text--goto-word (key)
  "Move point to the start of the word block identified by KEY."
  (goto-char (point-min))
  (let ((pos (text-property-any (point-min) (point-max) 'dharmamitra-word key)))
    (when pos
      (goto-char pos)
      (beginning-of-line))))

(defun dharmamitra-text-next-word (&optional arg)
  "Move to the next word block, or the ARGth next."
  (interactive "p")
  (dharmamitra-text--check-buffer)
  (dotimes (_ (or arg 1))
    (let* ((start (if (get-text-property (point) 'dharmamitra-word-start)
                      (or (next-single-property-change (point) 'dharmamitra-word-start)
                          (point-max))
                    (point)))
           (pos (text-property-any start (point-max) 'dharmamitra-word-start t)))
      (if pos
          (goto-char pos)
        (user-error "No further word entries")))))

(defun dharmamitra-text-previous-word (&optional arg)
  "Move to the previous word block, or the ARGth previous."
  (interactive "p")
  (dharmamitra-text--check-buffer)
  (dotimes (_ (or arg 1))
    (let ((pos (save-excursion
                 (beginning-of-line)
                 (let ((found nil))
                   (while (and (not found) (> (point) (point-min)))
                     (forward-line -1)
                     (when (get-text-property (point) 'dharmamitra-word-start)
                       (setq found (point))))
                   found))))
      (if pos
          (goto-char pos)
        (user-error "No previous word entries")))))

(defun dharmamitra-text-set-target-language (language)
  "Set the translation target LANGUAGE and rerun the analysis if one is shown."
  (interactive
   (list (completing-read
          (format "Target language (current %s): " dharmamitra-text-target-language)
          dharmamitra-text-target-languages nil nil nil nil
          dharmamitra-text-target-language)))
  (setq dharmamitra-text-target-language (string-trim language))
  (if (and (derived-mode-p 'dharmamitra-text-mode)
           (plist-get dharmamitra-text--state :text))
      (dharmamitra-text-rerun)
    (message "Dharmamitra target language set to %s" dharmamitra-text-target-language)))

(defun dharmamitra-text-set-source-language (language)
  "Set the source LANGUAGE and rerun the analysis if one is shown."
  (interactive
   (list (intern (completing-read
                  (format "Source language (current %s): " dharmamitra-text-source-language)
                  '("auto" "sanskrit" "pali" "tibetan" "chinese") nil t))))
  (setq dharmamitra-text-source-language language)
  (if (and (derived-mode-p 'dharmamitra-text-mode)
           (plist-get dharmamitra-text--state :text))
      (dharmamitra-text-rerun)
    (message "Dharmamitra source language set to %s" language)))

(defun dharmamitra-text-copy ()
  "Copy the result at point to the kill ring.
On the Original, Segmented, Lemmatized and Translation lines this copies
the value, inside a word block it copies the form, lemma and tag."
  (interactive)
  (dharmamitra-text--check-buffer)
  (let ((value (get-text-property (point) 'dharmamitra-copy)))
    (unless value
      (user-error "Nothing to copy here"))
    (kill-new value)
    (message "Copied: %s" (dharmamitra-text--truncate value 80))))

;;;; Commands

(defun dharmamitra-text--start (text &optional translation-only)
  "Start grammar analysis and translation of TEXT in the analysis buffer.
With TRANSLATION-ONLY non-nil, skip the grammar analysis and always
translate."
  (let* ((buffer (get-buffer-create dharmamitra-text-buffer-name))
         (id (setq dharmamitra-text--request-counter
                   (1+ dharmamitra-text--request-counter)))
         (language (dharmamitra-text--source-language text))
         (grammar-supported (and (not translation-only)
                                 (memq language '(sanskrit pali))))
         (translate (or translation-only dharmamitra-text-include-translation)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'dharmamitra-text-mode)
        (dharmamitra-text-mode))
      (setq dharmamitra-text--state
            (list :id id
                  :text text
                  :grammar (cond (grammar-supported nil)
                                 (translation-only (cons :skipped "skipped (translation only)"))
                                 (t (cons :skipped
                                          (format "not available for %s text" language))))
                  :translation (if translate nil 'disabled)
                  :expanded nil
                  :expand-all nil))
      (dharmamitra-text--render buffer)
      (goto-char (point-min)))
    (unless (get-buffer-window buffer)
      (display-buffer buffer dharmamitra-text-display-action))
    (when grammar-supported
      (dharmamitra-text--post-json
       dharmamitra-text-tagging-url
       (dharmamitra-text--tagging-payload text)
       (lambda (err http body)
         (dharmamitra-text--receive
          buffer id :grammar (dharmamitra-text--parse-grammar err http body)))))
    (when translate
      (dharmamitra-text--post-json
       dharmamitra-text-translation-url
       (dharmamitra-text--translation-payload text)
       (lambda (err http body)
         (dharmamitra-text--receive
          buffer id :translation (dharmamitra-text--parse-translation err http body)))))
    buffer))

(defun dharmamitra-text--region-or-line ()
  "Return the active region as a list (START END), or the current line."
  (if (use-region-p)
      (list (region-beginning) (region-end))
    (list (line-beginning-position) (line-end-position))))

(defun dharmamitra-text--region-text (start end)
  "Return the trimmed text between START and END, or signal an error."
  (let ((text (string-trim (buffer-substring-no-properties start end))))
    (when (string-empty-p text)
      (user-error "No text to analyze"))
    text))

;;;###autoload
(defun dharmamitra-text-analyze-grammar (start end)
  "Analyze grammar and translate the text between START and END.
Interactively, use the active region, or the current line when there is
no region.  Both requests are sent to the dharmamitra.org API
asynchronously and shown in `dharmamitra-text-buffer-name' as they arrive."
  (interactive (dharmamitra-text--region-or-line))
  (dharmamitra-text--start (dharmamitra-text--region-text start end)))

;;;###autoload
(defun dharmamitra-text-translate (start end)
  "Translate the text between START and END without grammar analysis.
Interactively, use the active region, or the current line when there is
no region.  This works for Sanskrit, Pāli, Tibetan and Chinese and
ignores `dharmamitra-text-include-translation'."
  (interactive (dharmamitra-text--region-or-line))
  (dharmamitra-text--start (dharmamitra-text--region-text start end) t))

;;;###autoload
(defun dharmamitra-text-analyze-string (text)
  "Prompt for TEXT and analyze it with the dharmamitra.org API."
  (interactive "sText to analyze: ")
  (let ((text (string-trim text)))
    (when (string-empty-p text)
      (user-error "No text to analyze"))
    (dharmamitra-text--start text)))

(provide 'dharmamitra)

;;; dharmamitra.el ends here
