(require 'json)

(defun buddhist-text-clean-response (response)
  "Clean the translation response by handling special characters."
  (let ((text response))
    ;; First escape any special regex characters in the text
    (setq text (replace-regexp-in-string "\\\\" "\\\\" text t t))
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

(defun buddhist-text-translate-region (start end)
  "Translate Sanskrit, Tibetan, Chinese or Pāli text in region using dharmamitra.org API."
  (interactive "r")
  (let* ((text (buffer-substring-no-properties start end))
         (json-data (json-encode
                    `(("input_sentence" . ,text)
                      ("input_encoding" . "auto")
                      ("target_lang" . "english"))))
         (buffer (get-buffer-create "*Buddhist Text Translation*"))
         (curl-command (format "curl -s -X POST -H \"Content-Type: application/json\" -d '%s' https://dharmamitra.org/api/translation-no-stream/"
                             (replace-regexp-in-string "'" "'\\''" json-data))))
    
    ;; Create or get translation buffer
    (with-current-buffer buffer
      (erase-buffer)
      (insert "Translating...\n"))
    
    ;; Display buffer in bottom window
    (unless (get-buffer-window buffer)
      (display-buffer buffer '(display-buffer-at-bottom)))
    
    ;; Execute curl command and process response
    (let ((response
           (with-temp-buffer
             (call-process-shell-command curl-command nil (current-buffer))
             (buffer-string))))
      
      (with-current-buffer buffer
        (erase-buffer)
        (let ((cleaned-response (buddhist-text-clean-response response)))
          (insert "Original:\n"
                  text
                  "\n\nTranslation:\n"
                  cleaned-response))))))

;; Add mode-specific hooks for convenient access
(defun buddhist-text-maybe-bind-keys ()
  "Bind translation keys if appropriate for the current mode."
  (local-set-key (kbd "C-c t") 'buddhist-text-translate-region))

(add-hook 'text-mode-hook 'buddhist-text-maybe-bind-keys)
(add-hook 'org-mode-hook 'buddhist-text-maybe-bind-keys)

;; Global key binding
(global-set-key (kbd "C-c t") 'buddhist-text-translate-region)

;; Optional: Add a menu item
(easy-menu-add-item nil '("Tools")
                    ["Translate Buddhist Text Region" buddhist-text-translate-region
                     :help "Translate selected Sanskrit, Tibetan, Chinese or Pāli text using dharmamitra.org"])
