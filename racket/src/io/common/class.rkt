#lang racket/base
(require (for-syntax racket/base
                     racket/struct-info)
         racket/stxparam)

;; A class system that is somewhat similar to `racket/class`, but
;; completely first order, with its structure nature exposed, and
;; where the notion of "method" is flexible to allow non-procedures in
;; the vtable.
;;
;;  <class-defn> = (class <class-id> <clause> ...)
;;               | (class <class-id> #:extends <class-id> <clause> ...)
;;  <clause> = (field [<field-id> <duplicatable-init-expr>] ...)
;;           | (public [<method-id> <method>] ...)
;;           | (private [<method-id> <method>] ...)
;;           | (override [<method-id> <method>] ...)
;;           | (property [<property-expr> <val-expr>] ...)
;;  <method> = #f
;;           | (lambda (<id> ...) <expr> ...+)
;;           | (case-lambda [(<id> ...) <expr> ...+] ...)
;;           | <expr> ; must have explicit `self`, etc.
;;
;; A <class-id> and its <field>s behave as if they are in
;; a `struct` declaration where `create-<class-id>` is the
;; constructor, but an extra `vtable` field is added to
;; the start of a class's structure if it has no superclass.
;; The `#:authentic` option is added implicitly.
;;
;; Normally, use
;;   (new <class-id> [<field-id> <expr] ...)
;; to create an instance of the class, where each unmentioned
;; <field-id> gets its default value. To override methods for just
;; this object, use
;;   (new <class-id> #:override ([<method-id> <method>] ...)
;;        [<field-id> <expr] ...)
;; but beware that it involves allocating a new vtable each
;; time the `new` expression is evaluated.
;;
;; Use
;;    (send <class-id> <obj-expr> <method-id> <arg-expr> ...)
;; to call a method, or
;;    (mewthod <class-id> <obj-expr> <method-id>)
;; to get a method that expects the object as its first argument.
;;
;; In a method, fields can be accessed directly by name, and `this` is
;; bound to the current object.

(provide class
         this
         new
         send
         method)

(define-syntax-parameter this
  (lambda (stx)
    (raise-syntax-error #f "illegal use outside of a method" stx)))

(begin-for-syntax
  (struct class-info (struct-info methods-id vtable-id vtable-accessor-id fields methods)
    #:property prop:struct-info (lambda (ci)
                                  (class-info-struct-info ci))))

(define-syntax (class stx)
  (define id (syntax-case stx ()
               [(_ id . _) #'id]))
  (define super-id (syntax-case stx ()
                     [(_ id #:extends super-id . _)
                      #'super-id]
                     [_ #f]))
  (define super-ci (and super-id
                        (syntax-local-value super-id)))
  (define (combine-ids ctx . elems)
    (datum->syntax ctx (string->symbol (apply string-append
                                              (for/list ([elem (in-list elems)])
                                                (if (string? elem)
                                                    elem
                                                    (symbol->string (syntax-e elem))))))))
  (define methods-id (combine-ids #'here id "-methods"))
  (define (add-procs base-id l what #:can-immutable? [can-immutable? #f])
    (for/list ([e (in-list l)])
      (syntax-case e ()
        [(id expr #:immutable)
         can-immutable?
         (list #'id #'expr (combine-ids base-id base-id "-" #'id) #f)]
        [(id expr)
         (list #'id #'expr (combine-ids base-id base-id "-" #'id) (combine-ids #'id "set-" base-id "-" #'id "!"))]
        [_ (raise-syntax-error #f (format "bad ~a clause" what) stx e)])))
  (define-values (new-fields new-methods override-methods locals properties)
    (let ([l-stx (syntax-case stx ()
                   [(_ _ #:extends _ . rest) #'rest]
                   [(_ _ . rest) #'rest])])
      (let loop ([l-stx l-stx] [new-fields null] [new-methods null] [override-methods null] [locals null] [properties null])
        (syntax-case l-stx (field public override private property)
          [() (values new-fields new-methods override-methods locals properties)]
          [((field fld ...) . rest)
           (loop #'rest
                 (add-procs id (syntax->list #'(fld ...)) "field" #:can-immutable? #t)
                 new-methods
                 override-methods
                 locals
                 properties)]
          [((public method ...) . rest)
           (loop #'rest
                 new-fields
                 (add-procs methods-id (syntax->list #'(method ...)) "public")
                 override-methods
                 locals
                 properties)]
          [((override method ...) . rest)
           (loop #'rest new-fields new-methods (syntax->list #'(method ...)) locals properties)]
          [((private method ...) . rest)
           (loop #'rest new-fields new-methods override-methods (syntax->list #'(method ...)) properties)]
          [((property prop ...) . rest)
           (loop #'rest new-fields new-methods override-methods locals (syntax->list #'((#:property . prop) ...)))]
          [(other . _)
           (raise-syntax-error #f "unrecognized" stx #'other)]))))
  (define all-fields (if super-ci
                         (append (class-info-fields super-ci) new-fields)
                         new-fields))
  (for ([override (in-list override-methods)])
    (syntax-case override ()
      [(method-id _) (check-member stx #'method-id (if super-ci (class-info-methods super-ci) null) "method")]
      [_ (raise-syntax-error #f "bad override clause" stx override)]))
  (with-syntax ([((field-id field-init-expr field-accessor-id field-mutator-maybe-id) ...) all-fields])
    (define wrapped-new-methods
      (for/list ([new-method (in-list new-methods)])
        (syntax-case new-method ()
          [(method-id method-init-expr . rest)
           #'(method-id (let ([method-id
                               (bind-fields-in-body
                                ([field-id field-accessor-id field-mutator-maybe-id] ...)
                                method-init-expr)])
                          method-id)
                        . rest)])))
    (define all-methods/vtable (if super-ci
                                   (append (for/list ([method (in-list (class-info-methods super-ci))])
                                             (syntax-case method ()
                                               [(method-id method-init-expr . rest)
                                                (or (for/or ([override (in-list override-methods)])
                                                      (syntax-case override ()
                                                        [(override-id override-init-expr . _)
                                                         (and (eq? (syntax-e #'method-id) (syntax-e #'override-id))
                                                              (list* #'method-id
                                                                     #'(let ([method-id
                                                                              (bind-fields-in-body
                                                                               ([field-id field-accessor-id field-mutator-maybe-id] ...)
                                                                               override-init-expr)])
                                                                         method-id)
                                                                     #'rest))]))
                                                    method)]))
                                           wrapped-new-methods)
                                   wrapped-new-methods))
    (define vtable-id (combine-ids #'here id "-vtable"))
    (define all-methods/next (for/list ([method (in-list all-methods/vtable)])
                               (syntax-case method ()
                                 [(method-id method-init-expr method-accessor-id . _)
                                  (with-syntax ([vtable-id vtable-id])
                                    (list #'method-id
                                          #'(method-accessor-id vtable-id)
                                          #'method-accessor-id))])))
    (with-syntax ([id id]
                  [(super-ids ...) (if super-id
                                       (list super-id)
                                       null)]
                  [quoted-super-id (and super-id #`(quote-syntax #,super-id))]
                  [(vtable-ids ...) (if super-id
                                        null
                                        (list (datum->syntax id 'vtable)))]
                  [vtable-accessor-id (if super-ci
                                          (class-info-vtable-accessor-id super-ci)
                                          (combine-ids id id "-vtable"))]
                  [vtable-id vtable-id]
                  [struct:id (combine-ids id "struct:" id)]
                  [make-id (combine-ids id "create-" id)]
                  [id? (combine-ids id id "?")]
                  [methods-id methods-id]
                  [(super-methods-ids ...) (if super-ci
                                               (list (class-info-methods-id super-ci))
                                               null)]
                  [(new-field-id/annotated ...) (for/list ([new-field (in-list new-fields)])
                                                  (syntax-case new-field ()
                                                    [(id _ _ #f) #'id]
                                                    [(id . _) #'[id #:mutable]]))]
                  [((new-method-id . _) ...) new-methods]
                  [((_ _ rev-field-accessor-id . _) ...) (reverse all-fields)]
                  [((_ _ _ rev-field-mutator-maybe-id) ...) (reverse all-fields)]
                  [((method-id method-init-expr/vtable . _) ...) all-methods/vtable]
                  [((_ method-init-expr/next  method-accessor-id) ...) all-methods/next]
                  [((local-id local-expr) ...) locals]
                  [(local-tmp-id ...) (generate-temporaries locals)]
                  [((propss ...) ...) properties])
      #`(begin
          (struct id super-ids ... (vtable-ids ... new-field-id/annotated ...)
            #:omit-define-syntaxes
            #:constructor-name make-id
            #:authentic
            propss ... ...)
          (struct methods-id super-methods-ids ... (new-method-id ...))
          (define vtable-id (methods-id method-init-expr/vtable ...))
          (begin
            (define local-tmp-id (let ([local-id
                                        (bind-fields-in-body ([field-id field-accessor-id field-mutator-maybe-id] ...)
                                                             local-expr)])
                                   local-id))
            (define-syntax (local-id stx)
              (syntax-case stx ()
                [(_ arg (... ...))
                 (with-syntax ([this-id (datum->syntax #'here 'this stx)])
                   (syntax/loc stx (local-tmp-id this-id arg (... ...))))])))
          ...
          (define-syntax id
            (class-info (list (quote-syntax struct:id)
                              (quote-syntax make-id)
                              (quote-syntax id?)
                              (list (quote-syntax rev-field-accessor-id) ... (quote-syntax vtable-accessor-id))
                              (list (maybe-quote-syntax rev-field-mutator-maybe-id) ... #f)
                              quoted-super-id)
                        (quote-syntax methods-id)
                        (quote-syntax vtable-id)
                        (quote-syntax vtable-accessor-id)
                        (list (list (quote-syntax field-id) (quote-syntax field-init-expr)
                                    (quote-syntax field-accessor-id) (maybe-quote-syntax field-mutator-maybe-id))
                              ...)
                        (list (list (quote-syntax method-id) (quote-syntax method-init-expr/next)
                                    (quote-syntax method-accessor-id))
                              ...)))))))

(define-syntax (bind-fields-in-body stx)
  (syntax-case stx (lambda case-lambda)
    [(_ fields #f) #'#f]
    [(_ fields (form . rest))
     #'(bind-fields-in-body fields form (form . rest))]
    [(_ fields ctx (lambda (arg ...) body0 body ...))
     #'(bind-fields-in-body fields ctx (case-lambda [(arg ...) body0 body ...]))]
    [(_ fields ctx (case-lambda clause ...))
     (with-syntax ([(new-clause ...)
                    (for/list ([clause (in-list (syntax->list #'(clause ...)))])
                      (syntax-case clause ()
                        [[(arg ...) body0 body ...]
                         (with-syntax ([(arg-tmp ...) (generate-temporaries #'(arg ...))])
                           #'[(this-id arg-tmp ...)
                              (syntax-parameterize ([this (make-rename-transformer #'this-id)])
                                (bind-fields
                                 fields
                                 this-id ctx
                                 (let-syntax ([arg (make-rename-transformer #'arg-tmp)] ...)
                                   body0 body ...)))])]))])
       (syntax/loc (syntax-case stx () [(_ _ _ rhs) #'rhs])
         (case-lambda new-clause ...)))]
    [(_ fields _ expr)
     #'expr]))

(define-syntax (bind-fields stx)
  (syntax-case stx ()
    [(_ ([field-id field-accessor-id field-mutator-maybe-id] ...) this-id ctx body)
     (with-syntax ([(field-id ...) (for/list ([field-id (in-list (syntax->list #'(field-id ...)))])
                                     (datum->syntax #'ctx (syntax-e field-id)))])
       #'(let-syntax ([field-id (make-set!-transformer
                                 (lambda (stx)
                                   (syntax-case stx (set!)
                                     [(set! _ rhs) (if (syntax-e (quote-syntax field-mutator-maybe-id))
                                                       (syntax/loc stx (field-mutator-maybe-id this-id rhs))
                                                       (raise-syntax-error #f "field is immutable" stx))]
                                     [(_ arg (... ...)) (syntax/loc stx ((field-accessor-id this-id) arg (... ...)))]
                                     [else (syntax/loc stx (field-accessor-id this-id))])))]
                      ...)
           body))]))

(define-syntax (new stx)
  (syntax-case stx ()
    [(_ class-id #:override (override ...) init ...)
     (let ([ci (and (identifier? #'class-id)
                    (syntax-local-value #'class-id (lambda () #f)))])
       (unless (class-info? ci)
         (raise-syntax-error #f "not a class identifier" stx #'class-id))
       (for ([init (in-list (syntax->list #'(init ...)))])
         (syntax-case init ()
           [(field-id _) (check-member stx #'field-id (class-info-fields ci) "field")]
           [_ (raise-syntax-error #f "bad field-inialization clause" stx init)]))
       (for ([override (in-list (syntax->list #'(override ...)))])
         (syntax-case override ()
           [(method-id _) (check-member stx #'method-id (class-info-methods ci) "method")]
           [_ (raise-syntax-error #f "bad method-override clause" stx override)]))
       (define field-exprs (for/list ([field (in-list (class-info-fields ci))])
                             (syntax-case field ()
                               [(field-id field-expr . _)
                                (or (for/or ([init (in-list (syntax->list #'(init ...)))])
                                      (syntax-case init ()
                                        [(id expr)
                                         (and (eq? (syntax-e #'id) (syntax-e #'field-id))
                                              #'expr)]))
                                    #'field-expr)])))
       (define overrides (syntax->list #'(override ...)))
       (with-syntax ([make-id (cadr (class-info-struct-info ci))]
                     [vtable-id (class-info-vtable-id ci)]
                     [(field-expr ...) field-exprs])
         (cond
           [(null? overrides)
            (syntax/loc stx (make-id vtable-id field-expr ...))]
           [else
            (with-syntax ([methods-id (class-info-methods-id ci)]
                          [(method-expr ...)
                           (for/list ([method (in-list (class-info-methods ci))])
                             (syntax-case method ()
                               [(id _ selector-id . _)
                                (or (for/or ([override (in-list overrides)])
                                      (syntax-case override ()
                                        [(override-id expr)
                                         (and (eq? (syntax-e #'override-id) (syntax-e #'id))
                                              (with-syntax ([((field-id _ field-accessor-id field-mutator-maybe-id) ...)
                                                             (class-info-fields ci)])
                                                #'(bind-fields-in-body
                                                   ([field-id field-accessor-id field-mutator-maybe-id] ...)
                                                   expr)))]))
                                    #'(selector-id vtable-id))]))])
              (syntax/loc stx (make-id (methods-id method-expr ...)
                                       field-expr ...)))])))]
    [(_ class-id init ...)
     (syntax/loc stx (new class-id #:override () init ...))]))

(define-for-syntax (send-or-method stx call?)
  (syntax-case stx ()
    [(_ class-id obj method-id arg ...)
     (let ([ci (and (identifier? #'class-id)
                    (syntax-local-value #'class-id (lambda () #f)))])
       (unless (class-info? ci)
         (raise-syntax-error #f "not a class identifier" stx #'class-id))
       (define method-accessor-id
         (or (for/or ([method (in-list (class-info-methods ci))])
               (syntax-case method ()
                 [(id _ accessor-id)
                  (and (eq? (syntax-e #'id) (syntax-e #'method-id))
                       #'accessor-id)]))
             (raise-syntax-error #f "cannot find method" stx #'method-id)))
       (with-syntax ([vtable-accessor-id (class-info-vtable-accessor-id ci)]
                     [method-accessor-id method-accessor-id])
         (if call?
             #'(let ([o obj])
                 ((method-accessor-id (vtable-accessor-id o)) o arg ...))
             #'(method-accessor-id (vtable-accessor-id obj)))))]))

(define-syntax (send stx)
  (send-or-method stx #t))

;; Gets a method to be called as a procedure, where the call must
;; include the "self" argument --- so, less safe than `send`, but
;; allows external handling for a method that is #f.
(define-syntax (method stx)
  (syntax-case stx ()
    [(_ class-id obj method-id)
     (send-or-method stx #f)]))

(define-for-syntax (check-member stx id l what)
  (or (for/or ([e (in-list l)])
        (syntax-case e ()
          [(e-id . _)
           (eq? (syntax-e #'e-id) (syntax-e id))]))
      (raise-syntax-error #f (format "no such ~a" what) stx id)))

(begin-for-syntax
  (define-syntax maybe-quote-syntax
    (syntax-rules ()
      [(_ #f) #f]
      [(_ e) (quote-syntax e)])))

;; ----------------------------------------

(module+ test
  (class example
    (field
     [a 1 #:immutable]
     [b 2])
    (private
      [other (lambda (q) (list q this))])
    (public
     [q #f]
     [m (lambda (z) (list a (other b)))]
     [n (lambda (x y z) (vector a b x y z))]))

  (class sub #:extends example
    (field
     [c 3]
     [d 4])
    (override
      [m (lambda (z) 'other)])
    (property
     [prop:custom-write (lambda (s o m)
                          (write 'sub: o)
                          (write (sub-d s) o))]))

  (define ex (new example [b 5]))

  (send example ex m 'ok)
  (method example ex m)
  (new sub [d 5])
  (send example (new sub) m 'more)
  (set-example-b! ex 6)

  (define ex2 (new example
                   #:override
                   ([q (lambda (x y z)
                         (box (vector x y z a b)))])
                   [b 'b]
                   [a 'a]))
  (send example ex2 n 1 2 3))