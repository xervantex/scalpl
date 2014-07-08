;;;; qd.lisp - quick and dirty. kraken's api... wow

(defpackage #:glock.qd
  (:use #:cl #:anaphora #:st-json #:local-time #:glock.util #:glock.connection))

(in-package #:glock.qd)

;;;
;;; Rate Gate
;;;

(defclass gate ()
  (key signer thread
   (in :initform (make-instance 'chanl:channel))))

(defun gate-loop (gate)
  (with-slots (key signer in) gate
    ;;                   / command structure \
    (destructuring-bind (command method &rest options) (chanl:recv in)
      (typecase command
        (symbol (setf (slot-value gate command) (apply method options)))
        (chanl:channel
         (chanl:send command
                     (multiple-value-list (post-request method key signer options))))))))

(defmethod initialize-instance :before ((gate gate) &key key secret)
  (setf (slot-value gate 'key) (glock.connection::make-key key)
        (slot-value gate 'signer) (glock.connection::make-signer secret)))

(defmethod shared-initialize :after ((gate gate) names &key)
  (when (or (not (slot-boundp gate 'thread))
            (eq :terminated (chanl:task-status (slot-value gate 'thread))))
    (setf (slot-value gate 'thread)
          (chanl:pexec (:name "qdm-preα gate"
                        :initial-bindings `((*read-default-float-format* double-float)))
            (loop (gate-loop gate))))))

(defun gate-request (gate path &optional options)
  (let ((out (make-instance 'chanl:channel)))
    (chanl:send (slot-value gate 'in)
                (list* out path options))
    (values-list (chanl:recv out))))

(defun get-assets ()
  (mapjso* (lambda (name data) (setf (getjso "name" data) name))
           (get-request "Assets")))

(defvar *assets* (get-assets))

(defun get-markets ()
  (mapjso* (lambda (name data) (setf (getjso "name" data) name))
           (get-request "AssetPairs")))

(defvar *markets* (get-markets))

;;; order-book and my-orders should both be in the same format:
;;; a list of (PRICE . AMOUNT), representing one side of the book
;;; TODO: deal with partially completed orders
(defun ignore-mine (order-book my-orders &aux new)
  (dolist (order order-book (nreverse new))
    (let ((mine (find (car order) my-orders :test #'= :key #'car)))
      (if mine
          (let ((without-me (- (cdr order) (cdr mine))))
            (setf my-orders (remove mine my-orders))
            (unless (< without-me 0.001)
              (push (cons (car order) without-me) new)))
          (push order new)))))

(defun open-orders (gate)
  (mapjso* (lambda (id order) (setf (getjso "id" order) id))
           (getjso "open" (gate-request gate "OpenOrders"))))

(defun cancel-order (gate order)
  (gate-request gate "CancelOrder"
                `(("txid" . ,(getjso "id" order)))))

(defun cancel-pair-orders (gate pair)
  (mapjso (lambda (id order)
            (declare (ignore id))
            (when (string= pair (getjso* "descr.pair" order))
              (cancel-order gate order)))
          (open-orders gate)))

(defparameter *validate* nil)

(define-condition volume-too-low () ())

(defun post-limit (gate type pair price volume decimals &optional options)
  (let ((price (/ price (expt 10d0 decimals))))
    (multiple-value-bind (info errors)
        (gate-request gate "AddOrder"
                      `(("ordertype" . "limit")
                        ("type" . ,type)
                        ("pair" . ,pair)
                        ("volume" . ,(format nil "~F" volume))
                        ("price" . ,(format nil "~F" price))
                        ,@(when options `(("oflags" . ,options)))
                        ,@(when *validate* `(("validate" . "true")))
                        ))
      (if errors
          (dolist (message errors)
            (if (search "volume" message)
                (if (search "viqc" options)
                    (return
                      ;; such hard code
                      (post-limit gate type pair price (+ volume 0.01) 0 options))
                    ;; (signal 'volume-too-low)
                    (return
                      (post-limit gate type pair price (* volume price) 0
                                  (apply #'concatenate 'string "viqc"
                                         (when options '("," options))))))
                (format t "~&~A~%" message)))
          (progn
            ;; theoretically, we could get several order IDs here,
            ;; but we're not using any of kraken's fancy forex nonsense
            (setf (getjso* "descr.id" info) (car (getjso* "txid" info)))
            (getjso "descr" info))))))

;;; TODO: Incorporate weak references and finalizers into the whole CSPSM model
;;; so they get garbage collected when there are no more references to the
;;; output channels

;;;
;;; TRADES
;;;

(defclass trades-tracker ()
  ((pair :initarg :pair)
   (control :initform (make-instance 'chanl:channel))
   (buffer :initform (make-instance 'chanl:channel))
   (output :initform (make-instance 'chanl:channel))
   (delay :initarg :delay :initform 27)
   (trades :initform nil)
   last updater worker))

(defun kraken-timestamp (timestamp)
  (multiple-value-bind (sec rem) (floor timestamp)
    (local-time:unix-to-timestamp sec :nsec (round (* (expt 10 9) rem)))))

(defun trades-since (pair &optional since)
  (with-json-slots (last (trades pair))
      (get-request "Trades" `(("pair" . ,pair)
                              ,@(when since `(("since" . ,since)))))
    (values (mapcar (lambda (trade)
                      (destructuring-bind (price volume time side kind data) trade
                        (let ((price  (read-from-string price))
                              (volume (read-from-string volume)))
                          (list (kraken-timestamp time)
                                ;; FIXME - "cost" later gets treated as precise
                                volume price (* volume price)
                                (concatenate 'string side kind data)))))
                    trades)
            last)))

(defgeneric vwap (tracker &key since type)
  (:method ((tracker trades-tracker) &key since type)
    (let ((trades (slot-value tracker 'trades)))
      (when since
        (setf trades (remove since trades :key #'car :test #'timestamp>=)))
      (when type
        (setf trades (remove (ccase type (buy #\b) (sell #\s)) trades
                             :key (lambda (trade) (char (fifth trade) 0))
                             :test-not #'char=)))
      (/ (reduce #'+ (mapcar #'fourth trades))
         (reduce #'+ (mapcar #'second trades))))))

(defun trades-worker-loop (tracker)
  (with-slots (control buffer output trades) tracker
    (chanl:select
      ((recv control command)
       ;; commands are (cons command args)
       (case (car command)
         ;; max - find max seen trade size
         (max (chanl:send output (reduce #'max (mapcar #'second trades))))
         ;; vwap - find vwap over recent trades
         (vwap (chanl:send output (apply #'vwap tracker (cdr command))))
         ;; pause - wait for any other command to restart
         (pause (chanl:recv control))))
      ((recv buffer raw-trades)
       (unless trades (push (pop raw-trades) trades))
       (setf trades
             (reduce (lambda (acc next &aux (prev (first acc)))
                       (if (and (> 0.3
                                   (local-time:timestamp-difference (first next)
                                                                    (first prev)))
                                (string= (fifth prev) (fifth next)))
                           (let* ((volume (+ (second prev) (second next)))
                                  (cost (+ (fourth prev) (fourth next)))
                                  (price (/ cost volume)))
                             (cons (list (first prev)
                                         volume price cost
                                         (fifth prev))
                                   (cdr acc)))
                           (cons next acc)))
                     raw-trades :initial-value trades)))
      (t (sleep 0.2)))))

(defun trades-updater-loop (tracker)
  (with-slots (pair buffer delay last) tracker
    (multiple-value-bind (raw-trades until)
        (handler-case (trades-since pair last)
          (unbound-slot () (trades-since pair)))
      (setf last until)
      (chanl:send buffer raw-trades)
      (sleep delay))))

(defmethod shared-initialize :after ((tracker trades-tracker) (slots t) &key)
  (with-slots (pair updater worker) tracker
    (when (or (not (slot-boundp tracker 'updater))
              (eq :terminated (chanl:task-status updater)))
      (setf updater
            (chanl:pexec
                (:name (concatenate 'string "qdm-preα trades updater for " pair)
                       :initial-bindings `((*read-default-float-format* double-float)))
              (loop (trades-updater-loop tracker)))))
    (when (or (not (slot-boundp tracker 'worker))
              (eq :terminated (chanl:task-status worker)))
      (setf worker
            (chanl:pexec (:name (concatenate 'string "qdm-preα trades worker for " pair))
              ;; TODO: just pexec anew each time...
              ;; you'll understand what you meant someday, right?
              (loop (trades-worker-loop tracker)))))))

;;;
;;; ORDER BOOK
;;;

(defclass book-tracker ()
  ((pair :initarg :pair)
   (control :initform (make-instance 'chanl:channel))
   (bids-output :initform (make-instance 'chanl:channel))
   (asks-output :initform (make-instance 'chanl:channel))
   (delay :initarg :delay :initform 8)
   bids asks updater worker))

(defun book-worker-loop (tracker)
  (with-slots (control bids asks bids-output asks-output) tracker
    (handler-case
        (chanl:select
          ((recv control command)
           ;; commands are (cons command args)
           (case (car command)
             ;; pause - wait for any other command to restart
             (pause (chanl:recv control))))
          ((send bids-output bids))
          ((send asks-output asks))
          (t (sleep 0.2)))
      (unbound-slot ()))))

;;; TODO: verify the number of decimals!
(defun parse-price (price-string decimals)
  (let ((dot (position #\. price-string)))
    (parse-integer (remove #\. price-string)
                   :end (+ dot decimals))))

(defun get-book (pair &optional count
                 &aux (decimals (getjso "pair_decimals"
                                        (getjso pair *markets*))))
  (with-json-slots (bids asks)
      (getjso pair
              (get-request "Depth"
                           `(("pair" . ,pair)
                             ,@(when count
                                     `(("count" . ,(princ-to-string count)))))))
    (flet ((parse (raw-order)
             (destructuring-bind (price amount timestamp) raw-order
               (declare (ignore timestamp))
               (cons (parse-price price decimals)
                     ;; the amount seems to always have three decimals
                     (read-from-string amount)))))
      (let ((asks (mapcar #'parse asks))
            (bids (mapcar #'parse bids)))
        (values asks bids)))))

(defun book-updater-loop (tracker)
  (with-slots (bids asks delay pair) tracker
    (setf (values asks bids) (get-book pair))
    (sleep delay)))

(defmethod shared-initialize :after ((tracker book-tracker) (names t) &key)
  (with-slots (updater worker pair) tracker
    (when (or (not (slot-boundp tracker 'updater))
              (eq :terminated (chanl:task-status updater)))
      (setf updater
            (chanl:pexec
                (:name (concatenate 'string "qdm-preα book updater for " pair)
                 :initial-bindings `((*read-default-float-format* double-float)))
              (loop (book-updater-loop tracker))))
    (when (or (not (slot-boundp tracker 'worker))
              (eq :terminated (chanl:task-status worker)))
      (setf worker
            (chanl:pexec (:name (concatenate 'string "qdm-preα book worker for " pair))
              ;; TODO: just pexec anew each time...
              ;; you'll understand what you meant someday, right?
              (loop (book-worker-loop tracker))))))))

;;;
;;; EXECUTION TRACKING
;;;

(defclass execution-tracker ()
  ((gate :initarg :gate)
   (delay :initform 30)
   (trades :initform nil)
   (control :initform (make-instance 'chanl:channel))
   (buffer :initform (make-instance 'chanl:channel))
   (since :initform (timestamp- (now) 6 :hour) :initarg :since)
   worker updater))

(defun raw-trades-history (tracker &key since until ofs)
  (macrolet ((check-bound (bound)
               `(setf ,bound
                      (ctypecase ,bound
                        (null nil)      ; (typep nil nil) -> nil
                        (string ,bound)
                        (timestamp
                         (princ-to-string (timestamp-to-unix ,bound)))
                        (jso (getjso "txid" ,bound))))))
    (check-bound since)
    (check-bound until))
  (gate-request (slot-value tracker 'gate) "TradesHistory"
                (append (when since `(("start" . ,since)))
                        (when until `(("end" . ,until)))
                        (when ofs `(("ofs" . ,ofs))))))

(defun trades-history-chunk (tracker &key until since)
  (with-slots (delay) tracker
    (with-json-slots (count trades)
        (apply #'raw-trades-history tracker
               (append (when until `(:until ,until))
                       (when since `(:since ,since))))
      (let* ((total (parse-integer count))
             (chunk (make-array (list total) :fill-pointer 0)))
        (flet ((process (trades-jso)
                 (mapjso (lambda (tid data)
                           (map nil (lambda (key)
                                      (setf (getjso key data)
                                            (read-from-string (getjso key data))))
                                '("price" "cost" "fee" "vol"))
                           (with-json-slots (txid time) data
                             (setf txid tid time (kraken-timestamp time)))
                           (vector-push data chunk))
                         trades-jso)))
          (when (zerop total)
            (return-from trades-history-chunk chunk))
          (process trades)
          (unless until
            (setf until (getjso "txid" (elt chunk 0))))
          (loop
             (when (= total (fill-pointer chunk))
               (return (sort chunk #'timestamp<
                             :key (lambda (o) (getjso "time" o)))))
             (sleep delay)
             (with-json-slots (count trades)
                 (apply #'raw-trades-history tracker
                        :until until :ofs (princ-to-string (fill-pointer chunk))
                        (when since `(:since ,since)))
               (let ((next-total (parse-integer count)))
                 (assert (= total next-total))
                 (process trades)))))))))

(defun execution-worker-loop (tracker)
  (with-slots (trades control buffer) tracker
    (chanl:select
      ((recv control channel) (chanl:send channel trades))
      ((recv buffer trade) (push trade trades))
      (t (sleep 0.2)))))

(defun execution-updater-loop (tracker)
  (with-slots (since gate buffer) tracker
    (loop
       for trade across (trades-history-chunk tracker :since since)
       do (chanl:send buffer trade)
       finally (when trade (setf since trade)))))

(defmethod shared-initialize :after ((tracker execution-tracker) slots &key)
  (with-slots (delay worker updater) tracker
    (when (or (not (slot-boundp tracker 'worker))
              (eq :terminated (chanl:task-status worker)))
      (setf worker
            (chanl:pexec (:name "qdm-preα execution worker")
              (loop (execution-worker-loop tracker)))))
    (when (or (not (slot-boundp tracker 'updater))
              (eq :terminated (chanl:task-status updater)))
      (setf updater
            (chanl:pexec (:name "qdm-preα execution updater"
                          :initial-bindings '((*read-default-float-format* double-float)))
              (loop
                 (sleep delay)
                 (execution-updater-loop tracker)))))))

;;;
;;;  ENGINE
;;;

(defclass ope ()
  ((gate :initarg :gate)
   (control :initform (make-instance 'chanl:channel))
   (response :initform (make-instance 'chanl:channel))
   thread))

(defun ope-interface-loop (ope)
  (with-slots (gate active control response) ope
    (let ((command (chanl:recv control)))
      (destructuring-bind (car . cdr) command
        (chanl:send response
                    (case car
                      (bid (apply #'post-limit gate "buy" cdr))
                      (ask (apply #'post-limit gate "sell" cdr))
                      (cancel (multiple-value-bind (ret err)
                                  (cancel-order gate cdr)
                                (or ret (search "Unknown order" (car err)))))))))))

(defmethod shared-initialize :after ((ope ope) slots &key)
  (with-slots (thread) ope
    (when (or (not (slot-boundp ope 'thread))
              (eq :terminated (chanl:task-status thread)))
      (setf thread
            (chanl:pexec (:name "qdm-preα ope interface"
                          :initial-bindings `((*read-default-float-format* double-float)))
              (loop (ope-interface-loop ope)))))))

(defun ope-bid (ope &rest data)
  (with-slots (control response) ope
    (chanl:send control `(bid ,@data "viqc"))
    (chanl:recv response)))

(defun ope-ask (ope &rest data)
  (with-slots (control response) ope
    (chanl:send control `(ask ,@data))
    (chanl:recv response)))

(defun ope-cancel (ope oid)
  (with-slots (control response) ope
    (chanl:send control (cons 'cancel oid))
    (chanl:recv response)))

;;;
;;; ACCOUNT TRACKING
;;;

(defclass account-tracker ()
  ((balances :initarg :balances :initform nil)
   (control :initform (make-instance 'chanl:channel))
   (gate :initarg :gate)
   (delay :initform 15)
   (lictor :initarg :lictor)
   (ope :initarg :ope)
   updater worker))

(defun account-worker-loop (tracker)
  (with-slots (balances control) tracker
    (let ((command (chanl:recv control)))
      (destructuring-bind (car . cdr) command
        (typecase car
          ;; ( asset . channel )  <- send asset balance to channel
          (string
           (chanl:send cdr (or (cdr (assoc car balances :test #'string=)) 0)))
          ;; ( slot . value ) <- update slot with new value
          (symbol (setf (slot-value tracker car) cdr)))))))

(defun account-updater-loop (tracker)
  (with-slots (gate control delay) tracker
    (chanl:send control
                (cons 'balances
                      (mapcar-jso (lambda (asset balance)
                                    (cons asset (read-from-string balance)))
                                  (gate-request gate "Balance"))))
    (sleep delay)))

(defmethod vwap ((tracker account-tracker) &key type pair &allow-other-keys)
  (let ((c (make-instance 'chanl:channel)))
    (chanl:send (slot-value (slot-value tracker 'lictor) 'control) c)
    (let ((trades (remove type (chanl:recv c)
                          :key (lambda (c) (getjso "type" c)) :test #'string/=)))
      (when pair
        (setf trades (remove pair trades
                             :key (lambda (c) (getjso "pair" c)) :test #'string/=)))
      (/ (reduce '+ (mapcar (lambda (x) (getjso "cost" x)) trades))
         (reduce '+ (mapcar (lambda (x) (getjso "vol" x)) trades))))))

(defmethod shared-initialize :after ((tracker account-tracker) (names t) &key)
  (with-slots (updater worker lictor gate ope) tracker
    (unless (slot-boundp tracker 'lictor)
      (setf lictor (make-instance 'execution-tracker :gate gate))
      ;; if this tracker has no trades, we can't calculate vwap
      ;; crappy solution... ideally w/condition system?
      (sleep 3))
    (unless (slot-boundp tracker 'ope)
      (setf ope (make-instance 'ope :gate gate)))
    (when (or (not (slot-boundp tracker 'updater))
              (eq :terminated (chanl:task-status updater)))
      (setf updater
            (chanl:pexec (:name "qdm-preα account updater"
                          :initial-bindings `((*read-default-float-format* double-float)))
              (loop (account-updater-loop tracker)))))
    (when (or (not (slot-boundp tracker 'worker))
              (eq :terminated (chanl:task-status worker)))
      (setf worker
            (chanl:pexec (:name "qdm-preα account worker")
              ;; TODO: just pexec anew each time...
              ;; you'll understand what you meant someday, right?
              (loop (account-worker-loop tracker)))))))

(defun asset-balance (tracker asset &aux (channel (make-instance 'chanl:channel)))
  (with-slots (control) tracker
    (chanl:send control (cons asset channel))
    (chanl:recv channel)))

(defun profit-margin (bid ask fee-percent)
  (* (/ ask bid) (- 1 (/ fee-percent 100))))

;;; Lossy trades

;;; The most common lossy trade execution happens when a limit order rolls
;;; through one or more offers but isn't filled, and thus remains on the
;;; books. If this order is large enough, it'll get outbid by the next round of
;;; the offer placement algorithm, and the outbidding offer will be lossy
;;; relative to the trades previously executed.

;;; How bad is this?

;;; In some situations, the remaining limit order gets traded back rapidly:
;; TUFCXE 12:26:33 buy  €473.22001 0.00020828 €0.09856
;; TJVT4U 12:26:33 buy  €473.22002 0.00004196 €0.01986
;; TRU2YT 12:24:05 buy  €474.04001 0.00108394 €0.51383
;; TOFJR2 12:23:52 sell €474.04000 0.00002623 €0.01243
;; TYWDQU 12:23:51 sell €473.98799 0.00074902 €0.35503
;; TINWGD 12:23:51 sell €473.95313 0.00028740 €0.13621
;; TPY7P4 12:23:51 sell €473.92213 0.00003772 €0.01788

(defun dumbot-oneside (book resilience funds delta max-orders predicate
                       &aux (acc 0) (share 0))
  ;; calculate cumulative depths
  (do* ((cur book (cdr cur))
        (n 0 (1+ n)))
       ((or (> acc resilience) (null cur))
        (let* ((sorted (sort (subseq book 1 n) #'> :key #'cddr))
               (n-orders (min max-orders n))
               (relevant (cons (car book) (subseq sorted 0 (1- n-orders))))
               (total-shares (reduce #'+ (mapcar #'car relevant))))
          (mapcar (lambda (order)
                    (let ((vol (* funds (/ (car order) total-shares))))
                      (cons vol (+ delta (cadr order)))))
                  (sort relevant predicate :key #'cddr))))
    ;; TODO - no side effects
    ;; TODO - use a callback for liquidity distribution control
    ;; (cdar cur) contains offer volume
    (push (incf share (* 11/6 (incf acc (cdar cur)))) (car cur))
    ;; (format t "~&Found ~$ at ~D total ~$ share ~$~%"
    ;;         (cddar cur) (cadar cur) acc share)
    ))

(defun gapps-rate (from to)
  (getjso "rate" (read-json (drakma:http-request
                             "http://rate-exchange.appspot.com/currency"
                             :parameters `(("from" . ,from) ("to" . ,to))
                             :want-stream t))))

(defun %round (maker)
  (with-slots (fee fund-factor resilience-factor targeting-factor
               pair (my-bids bids) (my-asks asks) gate
               trades-tracker book-tracker account-tracker)
      maker
    ;; whoo!
    (chanl:send (slot-value trades-tracker 'control) '(max))
    ;; Get our balances
    (let (;; TODO: split into base resilience and quote resilience
          (resilience (* resilience-factor
                         (chanl:recv (slot-value trades-tracker 'output))))
          ;; TODO: doge is cute but let's move on
          (doge/btc (with-slots (control output) trades-tracker
                      (chanl:send control `(vwap :since ,(timestamp- (now) 4 :hour)))
                      (chanl:recv output))))
      (flet ((symbol-funds (symbol) (asset-balance account-tracker symbol))
             (total-of (btc doge) (+ btc (/ doge doge/btc)))
             (factor-fund (fund factor) (* fund fund-factor factor)))
        (let* ((market (getjso pair *markets*))
               (decimals (getjso "pair_decimals" market))
               (price-factor (expt 10 decimals))
               (total-btc (symbol-funds (getjso "base" market)))
               (total-doge (symbol-funds (getjso "quote" market)))
               (total-fund (total-of total-btc total-doge))
               (investment (/ total-btc total-fund))
               (btc (factor-fund total-btc (* investment targeting-factor)))
               (doge (factor-fund total-doge (- 1 (* investment targeting-factor)))))
          ;; report funding
          ;; FIXME: modularize all this decimal point handling
          (let ((base-decimals (getjso "decimals" (getjso (getjso "base" market) *assets*)))
                (quote-decimals (getjso "decimals" (getjso (getjso "quote" market) *assets*))))
            ;; time, total, base, quote, invested, risked, risk bias, pulse
            (format t "~&~A ~V$ B ~V$ Q ~V$ I ~$% R ~$% B~@$ ~6@$%"
                    (format-timestring nil (now)
                                       :format '((:hour 2) #\:
                                                 (:min 2) #\:
                                                 (:sec 2)))
                    base-decimals  total-fund
                    base-decimals  total-btc
                    quote-decimals total-doge
                    (* 100 investment)
                    (* 100 (/ (total-of btc doge) total-fund))
                    (* 100 (/ (total-of (- btc) doge) total-fund))
                    ;; FIXME: take flow into account! this calculation lies!
                    ;; temporarily "fixed" by declaring that the calculation is valid
                    ;; since the timestamp of the earliest trade
                    (* 100 (1- (profit-margin (vwap account-tracker :type "buy" :pair pair)
                                              (vwap account-tracker :type "sell" :pair pair)
                                              fee)))))
          (force-output)
          ;; Now run that algorithm thingy
          (macrolet ((cancel-from (old place)
                       `(when (ope-cancel (slot-value account-tracker 'ope)
                                          (car ,old))
                          (setf ,place (remove ,old ,place)))))
            (flet ((filter-book (market-slot mine)
                     (ignore-mine (chanl:recv (slot-value book-tracker market-slot))
                                  (mapcar #'cdr mine))))
              (macrolet ((with-book (() &body body)
                           `(let ((other-bids (filter-book 'bids-output my-bids))
                                  (other-asks (filter-book 'asks-output my-asks)))
                              ;; NON STOP PARTY PROFIT MADNESS
                              (do* ((best-bid (caar other-bids) (caar other-bids))
                                    (best-ask (caar other-asks) (caar other-asks))
                                    (spread (profit-margin (1+ best-bid) (1- best-ask) fee)
                                            (profit-margin (1+ best-bid) (1- best-ask) fee)))
                                   ((> spread 1))
                                (ecase (round (signum (* (max 0 (- best-ask best-bid 10))
                                                         (- (cdar other-bids) (cdar other-asks)))))
                                  (-1 (decf (cdar other-asks) (cdr (pop other-bids))))
                                  (+1 (decf (cdar other-bids) (cdr (pop other-asks))))
                                  (0         (pop other-bids)      (pop other-asks))))
                              ,@body)))
                 ;; TODO: properly deal with partial and completed orders
                (setf
                 my-bids
                 (with-book ()
                   (let ((to-bid (dumbot-oneside other-bids resilience doge 1 15 #'>))
                         new-bids)
                     (flet ((place (new)
                              (let ((o (ope-bid (slot-value account-tracker 'ope)
                                                pair (cdr new) (car new) decimals)))
                                ;; rudimentary protection against too-small orders
                                (if o (push (cons o new) new-bids)
                                    (format t "~&Couldn't place ~S~%" new)))))
                       (dolist (old my-bids)
                         (let* ((new (find (cadr old) to-bid :key #'cdr :test #'=))
                                (same (and new (< (/ (abs (- (* price-factor
                                                                (/ (car new)
                                                                   (cdr new)))
                                                             (cddr old)))
                                                     (cddr old))
                                                  0.15))))
                           (if same (setf to-bid (remove new to-bid))
                               (dolist (new (remove (cadr old) to-bid
                                                    :key #'cdr :test #'>)
                                        (cancel-from old my-bids))
                                 (if (place new) (setf to-bid (remove new to-bid))
                                     (return (cancel-from old my-bids)))))))
                       (mapcar #'place to-bid))
                     ;; convert new orders into a saner format (for ignore-mine)
                     (sort (append my-bids
                                   (mapcar (lambda (order)
                                             (destructuring-bind (id quote-amount . price) order
                                               (list* id price
                                                      (* price-factor (/ quote-amount price)))))
                                           new-bids))
                           #'> :key #'cadr))))
                (setf
                 my-asks
                 (with-book ()
                   (let ((to-ask (dumbot-oneside other-asks resilience btc -1 15 #'<))
                         new-asks)
                     (flet ((place (new)
                              (let ((o (ope-ask (slot-value account-tracker 'ope)
                                                pair (cdr new) (car new) decimals)))
                                (if o (push (cons o new) new-asks)
                                    (format t "~&Couldn't place ~S~%" new)))))
                       (dolist (old my-asks)
                         (let* ((new (find (cadr old) to-ask :key #'cdr :test #'=))
                                (same (and new (< (/ (abs (- (car new)
                                                             (cddr old)))
                                                     (cddr old))
                                                  0.15))))
                           (if same (setf to-ask (remove new to-ask))
                               (dolist (new (remove (cadr old) to-ask
                                                    :key #'cdr :test #'<)
                                        (cancel-from old my-asks))
                                 (if (place new) (setf to-ask (remove new to-ask))
                                     (return (cancel-from old my-asks)))))))
                       (mapcar #'place to-ask))
                     ;; convert new orders into a saner format (for ignore-mine)
                     (sort (append my-asks
                                   (mapcar (lambda (order)
                                             (destructuring-bind (id quote-amount . price) order
                                               (list* id price quote-amount)))
                                           new-asks))
                           #'< :key #'cadr))))))))))))

(defclass maker ()
  ((pair :initarg :pair :initform "XXBTZEUR")
   (fund-factor :initarg :fund-factor :initform 1)
   (resilience-factor :initarg :resilience :initform 1)
   (targeting-factor :initarg :targeting :initform 1/2)
   (gate :initarg :gate)
   (control :initform (make-instance 'chanl:channel))
   (bids :initform nil :initarg :bids)
   (asks :initform nil :initarg :asks)
   (fee :initform 0.16 :initarg :fee)
   (trades-tracker :initarg :trades-tracker)
   (book-tracker :initarg :book-tracker)
   (account-tracker :initarg :account-tracker)
   thread))

(defun dumbot-loop (maker)
  (with-slots (control) maker
    (chanl:select
      ((recv control command)
       ;; commands are (cons command args)
       (case (car command)
         ;; pause - wait for any other command to restart
         (pause (chanl:recv control))
         (stream (setf *standard-output* (cdr command)))))
      (t (%round maker)))))

(defmethod shared-initialize :after ((maker maker) (names t) &key)
  (with-slots (gate pair trades-tracker book-tracker account-tracker thread) maker
    ;; FIXME: wtf is this i don't even
    (unless (slot-boundp maker 'trades-tracker)
      (setf trades-tracker (make-instance 'trades-tracker :pair pair))
      (sleep 12))
    (unless (slot-boundp maker 'book-tracker)
      (setf book-tracker (make-instance 'book-tracker :pair pair))
      (sleep 12))
    (unless (slot-boundp maker 'account-tracker)
      (setf account-tracker (make-instance 'account-tracker :gate gate))
      (sleep 12))
    (when (or (not (slot-boundp maker 'thread))
              (eq :terminated (chanl:task-status thread)))
      (setf thread
            (chanl:pexec
                (:name (concatenate 'string "qdm-preα " pair)
                 :initial-bindings `((*read-default-float-format* double-float)))
              ;; TODO: just pexec anew each time...
              ;; you'll understand what you meant someday, right?
              (loop (dumbot-loop maker)))))))

(defun pause-maker (maker)
  (with-slots (control) maker
    (chanl:send control '(pause))))

(defvar *maker*
  (make-instance 'maker
                 :gate (make-instance 'gate
                                      :key #P "secrets/kraken.pubkey"
                                      :secret #P "secrets/kraken.secret")))
