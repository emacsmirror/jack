;;; osta.el --- HTML renderer library -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021-2022 Tony Aldon

;;; commentary:

;;; code:

(defun osta-escape (s)
  "Return the string S with some caracters escaped.
`<', `>' and `&' are escaped."
  (replace-regexp-in-string
   "\\(<\\)\\|\\(>\\)\\|\\(&\\)\\|\\(\"\\)\\|\\('\\)"
   (lambda (m) (pcase m
                 ("<"  "&lt;")
                 (">"  "&gt;")
                 ("&"  "&amp;")
                 ("\"" "&quot;")
                 ("'"  "&apos;")))
   s))

(defvar osta-html-raise-error-p nil
  "When `t', `osta-html' raises an error when we pass it a non component object.

For instance, a vector like `[a b c]' can't be a component passed to `osta-html'.
If `nil', which is the default value, `osta-html' process non component object
as the empty string.

For instance,

  (let ((osta-html-raise-error-p nil))
    (osta-html \"foo\" [a b c] \"bar\")) ; \"foobar\"

and,

  (let ((osta-html-raise-error-p t))
    (osta-html \"foo\" [a b c] \"bar\"))

raises the error:

  \"Object '[a b c]' of type 'vector' can't be a component in 'osta-html'\"")

(defun osta-parse-tag-kw (tag-kw)
  "Return a list of (\"tag\" \"id\" \"class\") from a TAG-KW.
If TAG-KW is not a valid tag keyword, return nil.

For instance, `osta-parse-tag-kw' behaves like this:
    :div                    -> (\"div\" nil nil)
    :div/id                 -> (\"div\" \"id\" nil)
    :div.class              -> (\"div\" nil \"class\")
    :div/id.class           -> (\"div\" \"id\" \"class\")
    :div/id.class-1.class-2 -> (\"div\" \"id\" \"class-1 class-2\")"
  (if-let* (((keywordp tag-kw))
            (tag-s (symbol-name tag-kw))
            ((string-match (concat "\\(?::\\)\\([^ /.]+\\)"
                                   "\\(?:/\\([^ /.]+\\)\\)?"
                                   "\\(?:[.]\\([^ /]+\\)\\)?")
                           tag-s)))
      (let* ((tag (match-string 1 tag-s))
             (id (match-string 2 tag-s))
             (class (match-string 3 tag-s))
             (classes (and class (string-replace "." " " class))))
        (if (or tag id classes)
            (list tag id classes)
          (error "Wrong tag keyword: %S" tag-kw)))
    (error "Wrong tag keyword: %S" tag-kw)))

(defun osta-tag (tag-kw &optional attributes)
  "Return a plist describing the type of TAG-KW and its ATTRIBUTES.

Classes in TAG-KW (`.class') and ATTRIBUTES (`:class') are merged.
`:id' in ATTRIBUTES has priority over `/id' in TAG-KW.

For instance:

  (osta-tag :hr)

returns

  (:left \"<hr />\")

and:

  (osta-tag :div '(:id \"id\" :class \"class\"))

returns

  (:left  \"<div id=\"id\" class=\"class\">\"
   :right \"</div>\")
"
  (let ((void-tags '("area" "base" "br" "col" "embed" "hr" "img" "input"   ; https://developer.mozilla.org/en-US/docs/Glossary/Empty_element
                     "keygen" "link" "meta" "param" "source" "track" "wbr")))
    (seq-let (tag id classes) (osta-parse-tag-kw tag-kw)
      (let* ((kw->a (lambda (kw) (substring (symbol-name kw) 1))) ; :id -> "id"
             (p->a-v                                              ; (:id "foo") -> "id=\"foo\""
              (lambda (p)
                (let ((attr (funcall kw->a (car p))))
                  (pcase (eval (cadr p))
                    ('t (concat attr "=\""  attr "\""))
                    ('nil nil)
                    ((and _ value)
                     (concat attr "=\"" (osta-escape value) "\""))))))
             (pairs (seq-partition attributes 2))
             ;; we merge classes from `tag-kw' and `attributes' and add it to the pairs
             (-pairs (if classes
                         (if-let* ((c (assoc :class pairs)))
                             (let* ((pairs-without-class
                                     (seq-remove
                                      (lambda (p) (eq (car p) :class)) pairs))
                                    (class-value-in-pairs (cadr c))
                                    (class `(:class ,(concat classes " " class-value-in-pairs))))
                               (cons class pairs-without-class))
                           (cons `(:class ,classes) pairs))
                       pairs))
             ;; `id' in `attributes' has priority over `id' in `tag-kw'
             (--pairs (if (and id (not (assoc :id -pairs)))
                          (cons `(:id ,id) -pairs)
                        -pairs))
             (attrs (string-join (delq nil (mapcar p->a-v --pairs)) " "))
             (-attrs (if (string-empty-p attrs) "" (concat " " attrs))))
        (if (member tag void-tags)
            `(:left ,(concat "<" tag -attrs " />"))
          `(:left  ,(concat "<" tag -attrs ">")
            :right ,(concat "</" tag ">")))))))

(defun osta-html (&rest components)
  ""
  (let* ((update-tree-comp
          (lambda (tree comp)
            (let* ((comp-str (if (stringp comp) comp (number-to-string comp)))
                   (left (concat (plist-get tree :left) comp-str))
                   (right (plist-get tree :right)))
              `(:left ,left :right ,right))))
         (update-tree-tag
          (lambda (tree tag new-rest)
            (let* ((tag-left (plist-get tag :left))
                   (left (concat (plist-get tree :left) tag-left))
                   (tag-right (or (plist-get tag :right) ""))
                   (tree-right (plist-get tree :right))
                   (right (if new-rest
                              `(:left ,tag-right :right ,tree-right)
                            (concat tag-right tree-right))))
              `(:left ,left :right ,right))))
         (update-tree-rest
          (lambda (tree)
            (let* ((tree-left (plist-get tree :left))
                   (tree-right-left (plist-get (plist-get tree :right) :left))
                   (tree-right-right (plist-get (plist-get tree :right) :right))
                   (left (concat tree-left tree-right-left)))
              `(:left ,left :right ,tree-right-right))))
         ;; initialize state
         (tree '(:left "" :right ""))
         rest
         (comps components)
         (comp (car comps)))
    (while (or comp (cdr comps))
      (pcase comp
        ;; nil component is just ignored
        ('nil
         (setq comps (cdr comps))
         (setq comp (car comps)))
        ;; string component or an integer component
        ((or (pred stringp) (pred numberp))
         (setq tree (funcall update-tree-comp tree comp))
         (setq comps (cdr comps))
         (setq comp (car comps)))
        ;; not a tag component but a list of components like '("foo" "bar")
        ((and (pred listp) (guard (not (keywordp (car comp)))))
         (setq comps (append comp (cdr comps)))
         (setq comp (car comps)))
        ;; tag component like '(:p "foo") or '(:p/id.class (@ :attr "attr") "foo")
        ((pred listp)
         (let ((new-rest (cdr comps)))
           (seq-let (tag comp-children)
               (seq-let (tag-kw attr) comp
                 ;; check if `attr' is of the form '(@ :id "id" :class "class")
                 (if (and (listp attr) (equal (car attr) '@))
                     (list (osta-tag tag-kw (cdr attr)) (cddr comp))
                   (list (osta-tag tag-kw) (cdr comp))))
             (setq tree (funcall update-tree-tag tree tag new-rest))
             (when new-rest (push new-rest rest))
             (setq comps (append comp-children (and new-rest '(:rest))))
             (setq comp (car comps)))))
        ;; make the latest list of components added to `rest' the
        ;; part of `components' to be treated in the next iteration
        (:rest
         (setq tree (funcall update-tree-rest tree))
         (setq comps (pop rest))
         (setq comp (car comps)))
        ;; non component object
        ((and _ obj)
         (when osta-html-raise-error-p
           (error "Object '%S' of type '%s' can't be a component in 'osta-html'"
                  obj (type-of obj)))
         (setq comps (cdr comps))
         (setq comp (car comps)))))
    (concat (plist-get tree :left) (plist-get tree :right))))


(provide 'osta)
;;; org-bars.el ends here
