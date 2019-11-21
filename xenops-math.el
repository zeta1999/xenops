;; Terminology
;;
;; | math element   | either an inline element or a block element    |
;; | inline element | inline math delimited by $...$                 |
;; | block element  | e.g. a \begin{align}...\end{align} environment |


(defvar xenops-math-process 'dvisvgm)

(defvar xenops-math-image-change-size-factor 1.1
  "The factor by which the image's size will be changed under
  `xenops-math-image-increase-size' and
  `xenops-math-image-decrease-size'.")

(defvar xenops-math-image-scale-factor 0.8
  "Scaling factor for SVG math images. This determines the size
  of the image in the image file that is cached on disk.")

(defvar xenops-math-image-margin 20
  "Number of pixels to be used as left margin for non-inline math images")

(setq xenops-math-inline-math-delimiters '("\\$" . "\\$"))

(defun xenops-math-font-lock-keywords ()
  `((,(xenops-math-block-delimiter-lines-regexp)
     (0
      (xenops-math-block-delimiter-lines-set-face)))))

(defun xenops-math-activate ()
  (setq mouse-drag-and-drop-region t)
  (advice-add #'mouse-drag-region :around #'xenops-math-mouse-drag-region-around-advice)
  (advice-add fill-paragraph-function :after #'xenops-math-fill-paragraph-after-advice)
  (font-lock-add-keywords nil (xenops-math-font-lock-keywords))
  ;; TODO: DNW
  (add-to-list 'fill-nobreak-predicate (lambda () (xenops-math-in-inline-math-element-p "\\$"))))

(defun xenops-math-deactivate ()
  (advice-remove #'mouse-drag-and-drop-region #'xenops-math-mouse-drag-region-around-advice)
  (advice-remove fill-paragraph-function #'xenops-math-fill-paragraph-after-advice)
  (font-lock-remove-keywords nil (xenops-math-font-lock-keywords)))

(defun xenops-math-render (element &optional cached-only)
  (xenops-math-set-org-preview-latex-process-alist! element)
  (let ((beg (plist-get element :begin))
        (end (plist-get element :end)))
    (goto-char beg)
    (unless (xenops-math-get-image-at-point)
      (let* ((latex (buffer-substring-no-properties beg end))
             (image-type (plist-get (cdr (assq xenops-math-process
                                               org-preview-latex-process-alist))
                                    :image-output-type))
             (margin (if (xenops-math-inline-delimiters-p (plist-get element :delimiters))
                         0
                       `(,xenops-math-image-margin . 0)))
             (cache-file (xenops-math-compute-file-name latex image-type))
             (cache-file-exists? (file-exists-p cache-file)))
        (when (or cache-file-exists? (not cached-only))
          (unless cache-file-exists?
            (message "Xenops: creating file: %s" cache-file)
            (org-create-formula-image
             latex cache-file org-format-latex-options 'forbuffer xenops-math-process))
          (xenops-element-delete-overlays element)
          (xenops-math-make-overlay beg end cache-file image-type margin latex))))))

(defun xenops-math-regenerate (element)
  (let ((cache-file (xenops-math-get-cache-file element)))
    (when cache-file
      (delete-file cache-file)
      (clear-image-cache cache-file)
      (message "Xenops: deleted file: %s" cache-file))
    (xenops-element-delete-overlays element)
    (xenops-math-render element)))

(defun xenops-math-reveal (element)
  (org-remove-latex-fragment-image-overlays (plist-get element :begin)
                                            (plist-get element :end))
  (goto-char (plist-get element :begin-math)))

(defun xenops-math-image-increase-size (element)
  (xenops-math-image-change-size element xenops-math-image-change-size-factor))

(defun xenops-math-image-decrease-size (element)
  (xenops-math-image-change-size element (/ 1 xenops-math-image-change-size-factor)))

(defun xenops-math-image-change-size (element factor)
  (-when-let (image (xenops-math-get-image element))
    (when (eq (image-property image :type) 'svg)
      (image-flush image)
      (let* ((data (or (eval (image-property image :data))
                       (prog1 (f-read-text (image-property image :file))
                         (setf (image-property image :file) nil)))))
        (setf (image-property image :data) (xenops-util-svg-resize data factor))))))

(defun xenops-math-image-reset-size (element)
  (xenops-math-reveal element)
  (xenops-math-render element))

(defun xenops-math-get-math-element-begin-regexp ()
  "A regexp matching the start of any math element."
  (format "\\(%s\\)"
          (s-join "\\|"
                  (mapcar #'car (xenops-math-get-all-delimiters)))))

(defun xenops-math-block-delimiter-lines-regexp ()
  "A regexp matching the start or end line of any block math element."
  (format "\\(%s\\)"
          (s-join "\\|"
                  (apply #'append (mapcar (lambda (pair) (list (car pair) (cdr pair)))
                                          (xenops-element-get 'math :delimiters))))))

(defun xenops-math-block-delimiter-lines-set-face ()
  (add-face-text-property (match-beginning 0) (match-end 0) 'fixed-pitch))

(defun xenops-math-handle-return ()
  (when (xenops-math-get-image-at-point)
    (-when-let (element (xenops-math-parse-element-at-point))
      (xenops-math-reveal element)
      t)))

(defun xenops-math-handle-delete ()
  (when (xenops-math-get-image-at-point)
    (-when-let (element (xenops-math-parse-element-at-point))
      (kill-region (plist-get element :begin) (plist-get element :end))
      t)))

(defun xenops-math-handle-copy ()
  (when (xenops-math-get-image-at-point)
    (-when-let (element (xenops-math-parse-element-at-point))
      (xenops-math-copy element)
      t)))

(defun xenops-math-handle-paste ()
  "If the text to be pasted is a math element then handle the paste.
If we are in a math element, then paste without the delimiters"
  (let ((copied-text (current-kill 0 'do-not-rotate)))
    (-when-let (element (xenops-math-parse-element-from-string copied-text))
      (if (xenops-math-parse-element-at-point)
          (progn
            (insert-for-yank
             (substring copied-text
                        (plist-get element :begin-math)
                        (plist-get element :end-math)))
            (rotate-yank-pointer 1))
        (save-excursion (yank))
        (xenops-math-render (xenops-math-parse-element-at-point))
        t))))

(defun xenops-math-copy (element)
  (copy-region-as-kill (plist-get element :begin)
                       (plist-get element :end)))

(defun xenops-math-paste ()
  (or (xenops-math-handle-paste) (yank)))

(defun xenops-math-fill-paragraph-after-advice (&rest args)
  (let ((forward-paragraph-fn (if (fboundp 'LaTeX-forward-paragraph)
                                  'LaTeX-forward-paragraph
                                'forward-paragraph))
        (backward-paragraph-fn (if (fboundp 'LaTeX-backward-paragraph)
                                   'LaTeX-backward-paragraph
                                 'backward-paragraph)))
    (save-excursion
      ;; If point is at the start of a paragraph, LaTeX-fill-paragraph fills the paragraph
      ;; ahead. Therefore we move to the end before going back to locate the beginning.
      (funcall forward-paragraph-fn)
      (push-mark (point) t t)
      (funcall backward-paragraph-fn)
      (if (region-active-p)
          (xenops-render-if-cached)))))

(defun xenops-math-parse-element-from-string (element-string)
  (with-temp-buffer
    (save-excursion (insert element-string))
    (-when-let (element (xenops-math-parse-element-at-point))
      (when (eq (- (plist-get element :end)
                   (plist-get element :begin))
                (length element-string))
        element))))

(defun xenops-math-get-image-at-point ()
  (let ((display (get-char-property (point) 'display )))
    (and (eq (car display) 'image) display)))

(defun xenops-math-get-image (element)
  (save-excursion
    (goto-char (plist-get element :begin))
    (xenops-math-get-image-at-point)))

(defun xenops-math-toggle-on-transition (move-point-command)
  "Display LaTeX on entry to a math element; display image on exit."
  (if (region-active-p)
      (funcall move-point-command)
    (let ((was-in (xenops-math-parse-element-at-point))
          exited)
      (funcall move-point-command)
      (save-excursion
        (let* ((now-in (xenops-math-parse-element-at-point)))
          (setq exited (and was-in (not (equal was-in now-in))))
          (if exited (xenops-math-render was-in))))
      (and exited (eq move-point-command #'next-line)
           ;; Hack: with a single (next-line), point ends up to the right of the image; we want it
           ;; on the line below.
           (next-line)))))

(defun xenops-math-handle-mouse-1 (event)
  (interactive "e")
  (cond
   ((memq 'double (event-modifiers event))
    (xenops-math-handle-second-click event))
   (t (xenops-math-handle-first-click event))))

(defun xenops-math-handle-first-click (event)
  (let ((was-in (xenops-math-parse-element-at-point)))
    (mouse-set-point event)
    (save-excursion
      (let ((now-in (xenops-math-parse-element-at-point)))
        (and was-in (not (equal was-in now-in))
             (xenops-math-render was-in))))))

(defun xenops-math-handle-second-click (event)
  (-if-let (now-in (xenops-math-parse-element-at-point))
      (xenops-math-reveal now-in)))

(defun xenops-math-mouse-drag-region-around-advice (mouse-drag-region-fn start-event)
  "If point is in a math element, then cause mouse drag to appear to drag the associated image:
1. Select the math element as the currently active region.
2. Temporarily alter tooltip-show so that it displays the image."
  (-if-let (element (xenops-math-parse-element-at (posn-point (event-start start-event))))
      (progn
        (push-mark (plist-get element :begin))
        (goto-char (plist-get element :end))
        (let ((tooltip-show-fn (symbol-function 'tooltip-show))
              (image-tooltip (propertize " "
                                         'display
                                         ;; TODO: the file path should be stored somewhere, not recomputed.
                                         `(image . (:file ,(xenops-math-get-cache-file element) :type svg)))))
          (cl-letf (((symbol-function 'mouse-posn-property)
                     (lambda (&rest args) 'region))
                    ((symbol-function 'tooltip-show)
                     (lambda (text &rest args)
                       (apply tooltip-show-fn image-tooltip args))))
            (funcall mouse-drag-region-fn start-event))))
    (funcall mouse-drag-region-fn start-event)))

(defun xenops-math-parse-match (element)
  (xenops-math-parse-match- element
                            (plist-get element :delimiters)
                            (point-max)
                            (match-beginning 0)))

(defun xenops-math-parse-element-at (pos)
  (save-excursion
    (goto-char pos)
    (xenops-math-parse-element-at-point)))

(defun xenops-math-parse-element-at-point ()
  "If point is in previewable block, return plist describing match"
  (let* ((block-delimiters (xenops-element-get 'math :delimiters))
         (inline-delimiter (car (xenops-element-get 'inline-math :delimiters))))
    (or (xenops-math-in-inline-math-element-p (car inline-delimiter))
        (-any #'identity (mapcar
                          (lambda (pair)
                            (xenops-math-parse-element-at-point-matching-delimiters
                             pair
                             (point-min)
                             (point-max)))
                          block-delimiters)))))

(defun xenops-math-in-inline-math-element-p (delimiter)
  "Is point within an inline block delimited by `delimiter'?"
  (save-excursion
    (let ((odd-count (oddp (count-matches delimiter (point-at-bol) (point)))))
      (when (and (not odd-count) (looking-at (car xenops-math-inline-math-delimiters)))
        (forward-char)
        (setq odd-count t))
      (and odd-count
           (xenops-math-parse-element-at-point-matching-delimiters
            (cons delimiter delimiter) (point-at-bol) (point-at-eol))))))

(defun xenops-math-get-all-delimiters ()
  (append (xenops-element-get 'math :delimiters)
          (xenops-element-get 'inline-math :delimiters)))

(defun xenops-math-inline-delimiters-p (delimiters)
  (equal delimiters xenops-math-inline-math-delimiters))

(defun xenops-math-parse-element-at-point-matching-delimiters (delimiters lim-up lim-down)
  "If point is between regexps, return plist describing match"
  (-if-let (element
            (save-excursion
              (when (looking-at (cdr delimiters))
                ;; This function will return nil if point is between delimiters separated by
                ;; zero characters.
                (left-char))
              (xenops-math-parse-element-at-point-matching-delimiters- delimiters lim-up lim-down)))
      (append element `(:type math :delimiters ,delimiters))))

(defun xenops-math-parse-element-at-point-matching-delimiters- (delimiters lim-up lim-down)
  "`org-between-regexps-p' modified to return more match coordinates"
  (save-match-data ;; TODO: necessary?
    (let ((pos (point)))
      (save-excursion
        (and (or (org-in-regexp (car delimiters))
                 (re-search-backward (car delimiters) lim-up t))
             (xenops-math-parse-match- nil delimiters lim-down pos))))))

(defun xenops-math-parse-match- (element delimiters limit pos)
  "Based on `org-between-regexps-p'."
  (let (beg-beg beg-end end-beg end-end)
    (and (setq beg-beg (match-beginning 0))
         (goto-char (match-end 0))
         (skip-chars-forward " \t\n")
         (setq beg-end (point))
         (re-search-forward (cdr delimiters) limit t)
         (> (setq end-end (match-end 0)) pos)
         (goto-char (match-beginning 0))
         (skip-chars-backward " \t\n")
         (setq end-beg (point))
         (not (re-search-backward (car delimiters) (1+ beg-beg) t))
         (append element
                 `(:begin ,beg-beg :begin-math ,beg-end :end-math ,end-beg :end ,end-end)))))

(defun xenops-math-set-org-preview-latex-process-alist! (coords)
  (let* ((inline-p (xenops-math-inline-delimiters-p (plist-get coords :delimiters)))
         (bounding-box (if inline-p "1" "10"))
         (dvisvgm-process-plist (cdr (assoc 'dvisvgm org-preview-latex-process-alist)))
         (dvisvgm-image-converter (car (plist-get dvisvgm-process-plist
                                                  :image-converter))))
    ;; TODO: this mutates the global variable!
    (plist-put org-format-latex-options :scale xenops-math-image-scale-factor)
    (assert (and (string-match " -b \\([^ ]+\\) " dvisvgm-image-converter)
                 (plist-put dvisvgm-process-plist
                            :image-converter `(,(replace-match bounding-box t t
                                                               dvisvgm-image-converter 1)))))))

(defun xenops-math-make-overlay (beg end image-file image-type margin help-echo)
  "Copied from org--format-latex-make-overlay"
  (let ((ov (make-overlay beg end))
        (image-type (intern image-type)))
    (overlay-put ov 'org-overlay-type 'org-latex-overlay)
    (overlay-put ov 'xenops-overlay-type 'xenops-math-overlay)
    (overlay-put ov 'evaporate t)
    (overlay-put ov
                 'modification-hooks
                 (list (lambda (o _flag _beg _end &optional _l)
                         (delete-overlay o))))
    (overlay-put ov
                 'display
                 (list 'image :type image-type :file image-file :ascent 'center :margin margin))
    (overlay-put ov 'help-echo help-echo)))

(defun xenops-math-get-cache-file (element)
  (let* ((beg (plist-get element :begin))
         (end (plist-get element :end))
         (latex (buffer-substring-no-properties beg end))
         (image-type (plist-get (cdr (assq xenops-math-process
                                           org-preview-latex-process-alist))
                                :image-output-type)))
    (xenops-math-compute-file-name latex image-type)))

(defun xenops-math-file-name-static-hash-data ()
  (list org-format-latex-header
        org-latex-default-packages-alist
        org-latex-packages-alist
        org-format-latex-options))

(defun xenops-math-compute-file-name (latex image-type)
  (let* ((data (append (xenops-math-file-name-static-hash-data) (list latex)))
         (hash (sha1 (prin1-to-string data))))
    (format "%s.%s" (f-join (f-expand xenops-cache-directory) hash) image-type)))

(provide 'xenops-math)
