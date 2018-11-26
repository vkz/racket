#lang racket/base
(require racket/fasl
         "../host/linklet.rkt"
         "../host/correlate.rkt")

(provide correlated-linklet?
         make-correlated-linklet

         correlated-linklet-expr
         correlated-linklet-name

         force-compile-linklet

         correlated-linklet-vm-bytes
         write-correlated-linklet-bundle-hash
         read-correlated-linklet-bundle-hash)

(struct correlated-linklet (expr name [compiled #:mutable])
  #:authentic)

(define (make-correlated-linklet expr name)
  (correlated-linklet expr name #f))

;; ----------------------------------------

(define (force-compile-linklet l)
  (cond
    [(correlated-linklet? l)
     (or (correlated-linklet-compiled l)
         (let ([c (compile-linklet (correlated-linklet-expr l)
                                   (correlated-linklet-name l))])
           (set-correlated-linklet-compiled! l c)
           c))]
    [else l]))

;; ----------------------------------------

(define correlated-linklet-vm-bytes #"linklet")

(struct faslable-correlated (e source position line column span name)
  #:prefab)

(struct faslable-correlated-linklet (expr name)
  #:prefab)

;; ----------------------------------------

(define (write-correlated-linklet-bundle-hash ht o)
  (s-exp->fasl (->faslable ht) o))

(define (->faslable v)
  (cond
    [(pair? v)
     (define a (->faslable (car v)))
     (define d (->faslable (cdr v)))
     (if (and (eq? a (car v))
              (eq? d (cdr v)))
         v
         (cons a d))]
    [(correlated? v)
     (faslable-correlated
      (->faslable (correlated-e v))
      (correlated-source v)
      (correlated-position v)
      (correlated-line v)
      (correlated-column v)
      (correlated-span v)
      (correlated-property v 'inferred-name))]
    [(hash? v)
     (cond
       [(hash-eq? v)
        (for/hasheq ([(key value) (in-hash v)])
          (values (->faslable key) (->faslable value)))]
       [(hash-eqv? v)
        (for/hasheqv ([(key value) (in-hash v)])
          (values (->faslable key) (->faslable value)))]
       [else
        (for/hash ([(key value) (in-hash v)])
          (values (->faslable key) (->faslable value)))])]
    [(correlated-linklet? v)
     (faslable-correlated-linklet (->faslable (correlated-linklet-expr v))
                                  (->faslable (correlated-linklet-name v)))]
    [else v]))

;; ----------------------------------------

(define (read-correlated-linklet-bundle-hash in)
  (faslable-> (fasl->s-exp in)))

(define (faslable-> v)
  (cond
    [(pair? v)
     (define a (faslable-> (car v)))
     (define d (faslable-> (cdr v)))
     (if (and (eq? a (car v))
              (eq? d (cdr v)))
         v
         (cons a d))]
    [(faslable-correlated? v)
     (define name (faslable-correlated-name v))
     (define c (datum->correlated (faslable-> (faslable-correlated-e v))
                                  (vector
                                   (faslable-correlated-source v)
                                   (faslable-correlated-line v)
                                   (faslable-correlated-column v)
                                   (faslable-correlated-position v)
                                   (faslable-correlated-span v))))
     (if name
         (correlated-property c 'inferred-name name)
         c)]
    [(hash? v)
     (cond
       [(hash-eq? v)
        (for/hasheq ([(key value) (in-hash v)])
          (values (faslable-> key) (faslable-> value)))]
       [(hash-eqv? v)
        (for/hasheqv ([(key value) (in-hash v)])
          (values (faslable-> key) (faslable-> value)))]
       [else
        (for/hash ([(key value) (in-hash v)])
          (values (faslable-> key) (faslable-> value)))])]
    [(faslable-correlated-linklet? v)
     (make-correlated-linklet (faslable-> (faslable-correlated-linklet-expr v))
                              (faslable-> (faslable-correlated-linklet-name v)))]
    [else v]))