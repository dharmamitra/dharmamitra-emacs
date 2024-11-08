;;; dharmamitra-text-grammar.el --- Sanskrit/Pāli grammar analysis tool -*- lexical-binding: t -*-

;; Author: Sebastian Nehrdich 
;; Keywords: languages, tools
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))

;;; Commentary:
;; Provides translation and grammar analysis for Sanskrit/Pāli/Tibetan/Chinese texts using the dharmamitra.org API.

;;; Code:

(require 'json)

(defcustom dharmamitra-text-include-translation t
  "Whether to include translations in the grammar analysis output."
  :type 'boolean
  :group 'applications)

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

(defface dharmamitra-text-header-face
  '((t :inherit font-lock-comment-face :slant normal))
  "Face for category headers in Dharmamitra text analysis.")

(defun dharmamitra-text-format-analysis (analysis)
  "Format grammatical analysis into readable text with compact layout."
  (let ((result ""))
    (dolist (item (cdr (assoc 'grammatical_analysis analysis)))
      (let ((lemma (cdr (assoc 'lemma item)))
            (unsandhied (cdr (assoc 'unsandhied item)))
            (tag (cdr (assoc 'tag item)))
            (meanings (cdr (assoc 'meanings item))))
        (setq result 
              (concat result
                      "╭─ "
                      (propertize unsandhied 'face 'dharmamitra-text-word-face)
                      " ["
                      (propertize lemma 'face 'dharmamitra-text-lemma-face)
                      "]\n│  "
                      (propertize tag 'face 'dharmamitra-text-grammar-face)
                      "\n│  → "
                      (propertize (mapconcat 'identity meanings "; ") 
                                'face 'dharmamitra-text-meaning-face)
                      "\n╰────\n"))))
    result))

(defun dharmamitra-text-join-unsandhied (words)
  "Join unsandhied words, omitting spaces after hyphens."
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

(defun dharmamitra-text-get-forms (parsed-response)
  "Extract unsandhied and lemma forms from parsed response."
  (let ((unsandhied-forms '())
        (lemma-forms '()))
    (dolist (sentence parsed-response)
      (dolist (item (cdr (assoc 'grammatical_analysis sentence)))
        (push (cdr (assoc 'unsandhied item)) unsandhied-forms)
        (push (cdr (assoc 'lemma item)) lemma-forms)))
    (list (dharmamitra-text-join-unsandhied (reverse unsandhied-forms))
          (mapconcat 'identity (reverse lemma-forms) " "))))

(defun dharmamitra-text-clean-response (response)
  "Clean the translation RESPONSE by handling special characters."
  (let ((text response))
    ;; Remove escaped quotes
    (setq text (replace-regexp-in-string "\\\\\"" "\"" text t t))
    ;; Remove escaped backslashes
    (setq text (replace-regexp-in-string "\\\\\\\\" "\\" text t t))
    ;; Replace the downward arrow emoji with newline
    (setq text (replace-regexp-in-string "🔽" "\n" text t t))
    ;; Clean up any tabs
    (setq text (replace-regexp-in-string "\\\\t" "\t" text t t))
    ;; Clean up any remaining escaped newlines
    (setq text (replace-regexp-in-string "\\\\n" "\n" text t t))
    ;; Remove any null characters
    (setq text (replace-regexp-in-string "\000" "" text t t))
    ;; Normalize any whitespace
    (setq text (replace-regexp-in-string "[ \t\n\r]+" " " text t t))
    ;; Add proper paragraph breaks
    (setq text (replace-regexp-in-string " *\n *" "\n\n" text t t))
    text))

(defun dharmamitra-text-escape-for-shell (str)
  "Properly escape a string for shell commands, particularly handling single quotes."
  (let ((escaped-str (replace-regexp-in-string "'" "'\"'\"'" str)))
    (concat "'" escaped-str "'")))

(defun dharmamitra-text-get-translation (text)
  "Get translation for the given text using dharmamitra.org API."
  (let* ((json-data (json-encode
                    `(("input_sentence" . ,text)
                      ("input_encoding" . "auto")
                      ("target_lang" . "english"))))
         (curl-command (format 
                       "curl -s -X POST -H \"Content-Type: application/json\" -d %s https://dharmamitra.org/api/translation-no-stream/"
                       (dharmamitra-text-escape-for-shell json-data))))
    (with-temp-buffer
      (call-process-shell-command curl-command nil (current-buffer))
      (dharmamitra-text-clean-response (buffer-string)))))

(defun dharmamitra-text-animate-loading (buffer)
  "Animate loading indicator in buffer."
  (let ((dots "")
        (max-dots 3)
        (counter 0))
    (while (and (= (buffer-size buffer) 0)  ;; Keep animating until content appears
                (< counter 100))            ;; Timeout after ~10 seconds
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "╭───────────────────╮\n" 'face 'dharmamitra-text-header-face))
          (insert (propertize "│  " 'face 'dharmamitra-text-header-face))
          (insert (propertize "Analyzing" 'face 'dharmamitra-text-word-face))
          (insert (propertize dots 'face 'dharmamitra-text-word-face))
          (insert (propertize (make-string (- 3 (length dots)) ?\s) 'face 'dharmamitra-text-word-face))
          (insert (propertize "  │\n" 'face 'dharmamitra-text-header-face))
          (insert (propertize "╰───────────────────╯" 'face 'dharmamitra-text-header-face))))
      (setq dots (concat dots "."))
      (when (> (length dots) max-dots)
        (setq dots ""))
      (setq counter (1+ counter))
      (sit-for 0.3))))

(defun dharmamitra-text-analyze-grammar (start end)
  "Analyze grammar and translate text in region using dharmamitra.org API."
  (interactive "r")
  (let* ((text (buffer-substring-no-properties start end))
         (json-data (json-encode
                    `(("input_sentence" . ,text)
                      ("input_encoding" . "auto")
                      ("human_readable_tags" . t)
                      ("mode" . "unsandhied-lemma-morphosyntax"))))
         (buffer (get-buffer-create "*Dharmamitra Text Grammar*"))
         (curl-command (format 
                       "curl -s -X POST %s -H \"Content-Type: application/json\" -d %s"
                       "https://dharmamitra.org/api/tagging/"
                       (dharmamitra-text-escape-for-shell json-data))))
    
    ;; Create or get grammar analysis buffer and ensure it's writable
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)))
    
    ;; Display buffer in bottom window
    (unless (get-buffer-window buffer)
      (display-buffer buffer '(display-buffer-at-bottom)))
    
    ;; Start loading animation
    (make-thread
     (lambda () 
       (dharmamitra-text-animate-loading buffer)))
    
    ;; Execute commands and process responses
    (let* ((grammar-response
            (with-temp-buffer
              (call-process-shell-command curl-command nil (current-buffer))
              (buffer-string)))
           (json-array-type 'list)
           (parsed-response (json-read-from-string grammar-response))
           ;; Get translation regardless of grammar analysis result
           (translation (when dharmamitra-text-include-translation 
                        (dharmamitra-text-get-translation text))))
      
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (remove-overlays)
          
          ;; Insert original text for all cases
          (insert 
           (propertize "Original:   ⟦ " 'face 'dharmamitra-text-header-face)
           (propertize text 'face 'dharmamitra-text-word-face)
           (propertize " ⟧\n" 'face 'dharmamitra-text-header-face))
          
          ;; Check grammar analysis result
          (if (and (listp parsed-response) 
                   (equal (assoc-default 'detail parsed-response) "unsuccessful"))
              ;; Show grammar analysis failure and translation if enabled
              (progn
                (insert (propertize "Grammar analysis unsuccessful\n" 'face 'dharmamitra-text-header-face))
                (when dharmamitra-text-include-translation
                  (insert
                   (propertize "Translation: ⟦ " 'face 'dharmamitra-text-header-face)
                   (propertize translation 'face 'dharmamitra-text-meaning-face)
                   (propertize " ⟧\n" 'face 'dharmamitra-text-header-face))))
            
            ;; Process successful grammar analysis
            (let ((forms (dharmamitra-text-get-forms parsed-response)))
              (insert 
               (propertize "Segmented:  ⟦ " 'face 'dharmamitra-text-header-face)
               (propertize (car forms) 'face 'dharmamitra-text-word-face)
               (propertize " ⟧\n" 'face 'dharmamitra-text-header-face)
               (propertize "Lemmatized: ⟦ " 'face 'dharmamitra-text-header-face)
               (propertize (cadr forms) 'face 'dharmamitra-text-lemma-face)
               (propertize " ⟧\n" 'face 'dharmamitra-text-header-face))
              
              (when dharmamitra-text-include-translation
                (insert
                 (propertize "Translation: ⟦ " 'face 'dharmamitra-text-header-face)
                 (propertize translation 'face 'dharmamitra-text-meaning-face)
                 (propertize " ⟧\n" 'face 'dharmamitra-text-header-face)))
              
              (insert "\n")
              (dolist (sentence parsed-response)
                (insert (dharmamitra-text-format-analysis sentence)))))
          
          (goto-char (point-min)))))))

;; Add mode-specific hooks for convenient access
(defun dharmamitra-text-maybe-bind-grammar-keys ()
  "Bind grammar analysis keys if appropriate for the current mode."
  (local-set-key (kbd "C-c g") #'dharmamitra-text-analyze-grammar))

(add-hook 'text-mode-hook #'dharmamitra-text-maybe-bind-grammar-keys)
(add-hook 'org-mode-hook #'dharmamitra-text-maybe-bind-grammar-keys)

;; Global key binding
(global-set-key (kbd "C-c g") #'dharmamitra-text-analyze-grammar)

;; Add menu item
(easy-menu-add-item nil '("Tools")
                    ["Analyze Text with Dharmamitra" dharmamitra-text-analyze-grammar
                     :help "Analyze Sanskrit, Tibetan, Chinese or Pāli text using dharmamitra.org"])

(provide 'dharmamitra)

;;; dharmamitra-text-grammar.el ends here
