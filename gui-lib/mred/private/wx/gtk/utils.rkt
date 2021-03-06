#lang racket/base
(require racket/promise
	 ffi/unsafe
         ffi/unsafe/define
         ffi/unsafe/alloc
         racket/string
         racket/draw/unsafe/glib
         racket/draw/unsafe/bstr
         (only-in '#%foreign ctype-c->scheme)
	 "gtk3.rkt"
         "../common/utils.rkt"
         "types.rkt"
	 "resolution.rkt")

(provide
 gtk3?
 define-mz
 define-gobj
 define-glib
 (protect-out define-gtk
              define-gdk
              define-gdk_pixbuf

              g_object_ref
              g_object_ref_sink
              g_object_unref

              gobject-ref
              gobject-unref
              as-gobject-allocation

              as-gtk-allocation
              as-gtk-window-allocation
              clean-up-destroyed

              g_free
              _gpath/free
              _GSList
              gfree

              g_object_set_data
              g_object_get_data

              g_object_new

              (rename-out [g_object_get g_object_get_window])

              get-gtk-object-flags
              set-gtk-object-flags!

              define-signal-handler

              gdk_screen_get_default

              gtk_get_minor_version

              ;; for declaring derived structures:
              _GtkObject

	      ;; window size adjustments for screen scale:
	      ->screen ->screen* ->normal)
 mnemonic-string)

(define gdk-lib 
  (case (system-type)
    [(windows)
     (ffi-lib "libatk-1.0-0")
     (ffi-lib "libgio-2.0-0")
     (ffi-lib "libgdk_pixbuf-2.0-0")
     (ffi-lib "libgdk-win32-2.0-0")]
    [else (if gtk3?
	      (get-gdk3-lib)
	      (ffi-lib "libgdk-x11-2.0" '("0" "")))]))
(define gdk_pixbuf-lib 
  (case (system-type)
    [(windows)
     (ffi-lib "libgdk_pixbuf-2.0-0")]
    [(unix)
     (if gtk3?
	 #f
	 (ffi-lib "libgdk_pixbuf-2.0" '("0" "")))]
    [else gdk-lib]))
(define gtk-lib
  (case (system-type)
    [(windows) 
     (ffi-lib "libgtk-win32-2.0-0")]
    [else (if gtk3?
	      (get-gtk3-lib)
	      (ffi-lib "libgtk-x11-2.0" '("0" "")))]))

(define-ffi-definer define-gtk gtk-lib)
(define-ffi-definer define-gdk gdk-lib)
(define-ffi-definer define-gdk_pixbuf gdk_pixbuf-lib)

(define-gobj g_object_ref (_fun _pointer -> _pointer))
(define-gobj g_object_unref (_fun _pointer -> _void))
(define-gobj g_object_ref_sink (_fun _pointer -> _pointer))

(define gobject-unref ((deallocator) g_object_unref))
(define gobject-ref ((allocator gobject-unref) g_object_ref))

(define-syntax-rule (as-gobject-allocation expr)
  ((gobject-allocator (lambda () expr))))

(define gobject-allocator (allocator gobject-unref))

(define-gtk gtk_widget_destroy (_fun _GtkWidget -> _void))

(define gtk-destroy ((deallocator) (lambda (v)
                                     (gtk_widget_destroy v)
                                     (g_object_unref v))))

(define gtk-allocator (allocator remember-to-free-later))
(define (clean-up-destroyed)
  (free-remembered-now gtk-destroy))

(define-syntax-rule (as-gtk-allocation expr)
  ((gtk-allocator (lambda () (let ([v expr])
                               (g_object_ref_sink v)
                               v)))))
(define-syntax-rule (as-gtk-window-allocation expr)
  ((gtk-allocator (lambda () (let ([v expr])
                               (g_object_ref v)
                               v)))))

(define-glib g_free (_fun _pointer -> _void))
(define gfree ((deallocator) g_free))

(define-gobj g_object_set_data (_fun _GtkWidget _string _pointer -> _void))
(define-gobj g_object_get_data (_fun _GtkWidget _string -> _pointer))

(define-gobj g_signal_connect_data (_fun _gpointer _string _fpointer _pointer _fnpointer _int -> _ulong))
(define G_CONNECT_AFTER 1)
(define (g_signal_connect obj s proc user-data after?)
  (g_signal_connect_data obj s proc user-data #f (if after? G_CONNECT_AFTER 0)))

(define-gobj g_object_get (_fun _GtkWidget (_string = "window") 
				[w : (_ptr o _GdkWindow)]
				(_pointer = #f) -> _void -> w))

(define-gobj g_object_new (_fun _GType _pointer -> _GtkWidget))

;; This seems dangerous, since the shape of GtkObject is not
;;  documented. But it seems to be the only way to get and set
;;  flags.
(define-cstruct _GtkObject ([type-instance _pointer]
                            [ref_count _uint]
                            [qdata _pointer]
                            [flags _uint32]))
(define (get-gtk-object-flags gtk)
  (GtkObject-flags (cast gtk _pointer _GtkObject-pointer)))
(define (set-gtk-object-flags! gtk v)
  (unless gtk3?
    (set-GtkObject-flags! (cast gtk _pointer _GtkObject-pointer) v)))

(define-gmodule g_module_open (_fun _path _int -> _pointer))

(define-syntax-rule (define-signal-handler 
                      connect-name
                      signal-name
                      (_fun . args)
                      proc)
  (begin
    (define handler-proc proc)
    (define handler_function
      (function-ptr handler-proc (_fun #:atomic? #t . args)))
    (define (connect-name gtk [user-data #f] #:after? [after? #f])    
      (g_signal_connect gtk signal-name handler_function user-data after?))))


(define _gpath/free
  (make-ctype _pointer
              path->bytes ; a Racket bytes can be used as a pointer
              (lambda (x)
                (let ([b (bytes->path (make-byte-string x))])
                  (g_free x)
                  b))))

(define-cstruct _g-slist
  ([data _pointer]
   [next (_or-null _g-slist-pointer)]))

(define-glib g_slist_free (_fun _g-slist-pointer -> _void))
(define (make-byte-string s)
  (scheme_make_sized_byte_string s -1 1))

(define (_GSList elem)
  (make-ctype (_or-null _g-slist-pointer)
              (lambda (l)
                (let L ([l l])
                  (if (null? l) 
                      #f
                      (make-g-slist (car l) (L (cdr l))))))
              (lambda (gl)
                (begin0
                 (let L ([gl gl])
                   (if (not gl) 
                       null
                       (cons ((ctype-c->scheme elem) (g-slist-data gl))
                             (L (g-slist-next gl)))))
                 (g_slist_free gl)))))

(define-gdk gdk_screen_get_default (_fun -> _GdkScreen))

(define-gtk gtk_get_minor_version (_fun -> _uint)
  #:fail (lambda () (lambda () 0)))

(define (mnemonic-string orig-s)
  (string-join
   (for/list ([s (in-list (regexp-split #rx"&&" orig-s))])
     (regexp-replace*
      #rx"&(.)"
      (regexp-replace*
       #rx"_" 
       s
       "__")
      "_\\1"))
   "&"))

;; ----------------------------------------

(define screen-scale-factor/promise
  (delay
    (inexact->exact (get-interface-scale-factor 0))))

(define (->screen x)
  (define screen-scale-factor
    (force screen-scale-factor/promise))
  (and x
       (if (= screen-scale-factor 1)
	   x
	   (if (exact? x)
	       (ceiling (* x screen-scale-factor))
	       (* x screen-scale-factor)))))
(define (->screen* x)
  (define screen-scale-factor
    (force screen-scale-factor/promise))
  (if (and (not (= screen-scale-factor 1))
	   (exact? x))
      (floor (* x screen-scale-factor))
      (->screen x)))

(define (->normal x)
  (define screen-scale-factor
    (force screen-scale-factor/promise))
  (and x
       (if (= screen-scale-factor 1)
	   x
	   (if (exact? x)
	       (floor (/ x screen-scale-factor))
	       (/ x screen-scale-factor)))))
