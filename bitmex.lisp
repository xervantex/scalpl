(defpackage #:scalpl.bitmex
  (:nicknames #:bitmex) (:export #:*bitmex* #:bitmex-gate)
  (:use #:cl #:base64 #:chanl #:anaphora #:local-time #:scalpl.util
        #:scalpl.actor #:scalpl.exchange))

(in-package #:scalpl.bitmex)

;;; General Parameters
(defparameter *base-url* "https://www.bitmex.com")
(defparameter *base-path* "/api/v1/")
(setf cl+ssl:*make-ssl-client-stream-verify-default* ())

(defvar *bitmex* (make-instance 'exchange :name :bitmex))

(defclass bitmex-market (market)
  ((exchange :initform *bitmex*) (fee :initarg :fee :reader fee)
   (metallic :initarg :metallic)))

(defun hmac-sha256 (message secret)
  (let ((hmac (ironclad:make-hmac (string-octets secret) 'ironclad:sha256)))
    (ironclad:update-hmac hmac (string-octets message))
    (ironclad:octets-to-integer (ironclad:hmac-digest hmac))))

(defgeneric make-signer (secret)
  (:method ((signer function)) signer)
  (:method ((string string))
    (lambda (message) (format () "~(~64,'0X~)" (hmac-sha256 message string))))
  (:method ((stream stream)) (make-signer (read-line stream)))
  (:method ((path pathname)) (with-open-file (data path) (make-signer data))))

(defgeneric make-key (key)
  (:method ((key string)) key)
  (:method ((stream stream)) (read-line stream))
  (:method ((path pathname))
    (with-open-file (stream path)
      (make-key stream))))

(defun bitmex-request (path &rest args)
  (multiple-value-bind (json status headers)
      (apply #'http-request (concatenate 'string *base-url* path) args)
    (let ((data (decode-json json)))
      (sleep (aif (getjso :x-ratelimit-remaining headers)
                  (/ 42 (parse-integer it)) 1))
      (if (= status 200) (values data 200)
          (values () status (getjso "error" data))))))

(defun bitmex-path (&rest paths)
  (apply #'concatenate 'string *base-path* paths))

(defun public-request (method parameters)
  (bitmex-request
   (apply #'bitmex-path method
          (and parameters `("?" ,(net.aserve:uridecode-string
                                  (urlencode-params parameters)))))))

(defun auth-request (verb method key signer &optional params)
  (let* ((data (urlencode-params params))
         (path (apply #'bitmex-path method
                      (and (eq verb :get) params `("?" ,data))))
         (nonce (format () "~D" (+ (timestamp-millisecond (now))
                                   (* 1000 (timestamp-to-unix (now))))))
         (sig (funcall signer
                       (concatenate 'string (string verb) path nonce
                                    (unless (eq verb :get) data)))))
    (apply #'bitmex-request path
           :url-encoder (lambda (url format) (declare (ignore format)) url)
           :additional-headers `(("api-signature" . ,sig)
                                 ("api-key" . ,key) ("api-nonce" . ,nonce))
           :method verb (unless (eq verb :get) `(:content ,data)))))

(defun get-info (&aux assets)
  (declare (optimize debug))
  (awhen (public-request "instrument/active" ())
    (flet ((make-market (instrument)
             (with-json-slots
                 ((tick "tickSize") (lot "lotSize") (fee "takerFee")
                  (name "symbol") (fe "isInverse") (long "rootSymbol")
                  (short "quoteCurrency") multiplier)
                 instrument
               (flet ((asset (fake &optional (decimals 0))
                        (let ((name (concatenate 'string fake "-" name)))
                          (or (find name assets :key #'name :test #'string=)
                              (aprog1 (make-instance 'asset :name name
                                                     :decimals decimals)
                                (push it assets)))))
                      (ilog (i) (round (log (abs i) 10))))
                 (make-instance
                  'bitmex-market :name name :fee fee :metallic fe
                  :decimals (- (ilog tick))
                  :primary (asset long (ilog (if fe multiplier lot)))
                  :counter (asset short (ilog (if fe lot multiplier))))))))
      (values (mapcar #'make-market it) assets))))

(defmethod fetch-exchange-data ((exchange (eql *bitmex*)))
  (with-slots (markets assets) exchange
    (setf (values markets assets) (get-info))))

(defun swagger ()                       ; TODO: swagger metaclient!
  (decode-json (http-request (concatenate 'string *base-url*
                                          "/api/explorer/swagger.json"))))

(defclass bitmex-gate (gate) ((exchange :initform *bitmex*)))

(defmethod gate-post ((gate (eql *bitmex*)) key secret request)
  (destructuring-bind ((verb method) . parameters) request
    (multiple-value-bind (ret status error)
        (auth-request verb method key secret parameters)
      (case status (200 (list ret ()))
            (t (list (warn (getjso "message" error)) error))))))

(defmethod shared-initialize ((gate bitmex-gate) names &key pubkey secret)
  (multiple-value-call #'call-next-method gate names
                       (mvwrap pubkey make-key) (mvwrap secret make-signer)))

;;;
;;; Public Data API
;;;

(defmethod get-book ((market bitmex-market) &key (count 200)
                     &aux (pair (name market)))
  (loop for raw in
       (public-request "orderBook/L2" `(("symbol" . ,pair)
                                        ("depth" . ,(prin1-to-string count))))
     for price = (getjso "price" raw)
     for type = (string-case ((getjso "side" raw)) ("Sell" 'ask) ("Buy" 'bid))
     for offer = (make-instance type :market market
                                :price (* (expt 10 (decimals market)) price)
                                :volume (/ (getjso "size" raw) price))
     if (eq type 'ask) collect offer into asks
     if (eq type 'bid) collect offer into bids
     finally (return (values (nreverse asks) bids))))

(defmethod trades-since ((market bitmex-market) &optional since
                         &aux (pair (name market)))
  (awhen (public-request
          "trade" `(("symbol" . ,pair)
                    ("startTime"
                     . ,(format-timestring
                         () (or (timestamp since) (timestamp- (now) 1 :hour))
                         :format (butlast +iso-8601-format+ 3)))))
    (mapcar (lambda (trade)
              (with-json-slots (side timestamp size price) trade
                (make-instance 'trade :market market :direction side
                               :timestamp (parse-timestring timestamp)
                               :volume (/ size price) :price price :cost size)))
            (butlast it))))

;;;
;;; Private Data API
;;;

(defmethod placed-offers ((gate bitmex-gate))
  (awhen (gate-request gate '(:get "order") '(("filter" . "{\"open\": true}")))
    (mapcar (lambda (data)
              (with-json-slots
                  (symbol side price (oid "orderID") (size "orderQty")) data
                (let ((market (find-market symbol :bitmex))
                      (aksp (string-equal side "Sell")))
                  (make-instance 'placed :oid oid :market market
                                 :volume (/ size price)
                                 :price (* price (if aksp 1 -1)
                                           (expt 10 (decimals market)))))))
            it)))

(defmethod account-balances ((gate bitmex-gate) &aux balances)
  (declare (optimize debug))
  ;; tl;dr - transubstantiates position into 'balances' of long + short
  (let ((deposit (gate-request gate '(:get "user/wallet") ()))
        (positions (gate-request gate '(:get "position") ()))
        (instruments (public-request "instrument/active" ())))
    (dolist (instrument instruments balances)
      (with-json-slots (symbol (mark "markPrice")) instrument
        (with-slots (primary counter metallic) (find-market symbol :bitmex)
          (let* ((delta 0)
                 (fund (/ (* 50 (getjso "amount" deposit)) (if metallic 1 mark)
                          (expt 10 (decimals (if metallic primary counter))))))
            (awhen (find symbol positions :test #'string= :key (getjso "symbol"))
              (incf delta (/ (getjso "currentQty" it) mark)))
            (push (cons-aq* primary (+ fund delta)) balances)
            (push (cons-aq* counter (* (- fund delta) mark))
                  balances)))))))

(defmethod market-fee ((gate bitmex-gate) market) (fee market))

(defun parse-execution (raw)
  (with-json-slots ((oid "orderID") (txid "execID") (amt "lastQty")
                    symbol side price timestamp (execost "execCost")
                    (execom "execComm")) raw
    (unless (zerop (length side))
      (let ((market (find-market symbol :bitmex)))
        (flet ((adjust (value)
                 (/ value (expt 10 (decimals (primary market))))))
          (let ((volume (adjust execost)) (fee (adjust execom)))
            (list (make-instance 'execution :direction side :market market
                                 :oid oid :txid txid :cost amt :net-cost amt
                                 :price price :volume (abs volume)
                                 :timestamp (parse-timestamp *bitmex* timestamp)
                                 :net-volume (abs (+ volume fee))))))))))

(defun raw-executions (gate &key pair from end count)
  (macrolet ((params (&body body)
               `(append ,@(loop for (val key exp) in body
                             collect `(when ,val `((,,key . ,,exp)))))))
    (gate-request gate '(:get "execution/tradeHistory")
                  (params (pair "symbol" pair) (count "count" count)
                          (from "startTime" (subseq (princ-to-string from) 0 19))
                          (end "endTime" (subseq (princ-to-string end) 0 19))))))

(defmethod parse-timestamp ((exchange (eql *bitmex*)) (timestamp string))
  (parse-rfc3339-timestring timestamp))

(defmethod execution-since ((gate bitmex-gate) market since)
  (awhen (raw-executions gate :pair (name market)
                         :from (if since (timestamp since)
                                   (timestamp- (now) 1 :hour)))
    (mapcan #'parse-execution
            (if (null since) it
                (subseq it (1+ (position (txid since) it
                                         :test #'string= :key #'cdar)))))))

(defun post-raw-limit (gate buyp market price size)
  (gate-request gate '(:post "order")
                `(("symbol" . ,market) ("price" . ,(princ-to-string price))
                  ("orderQty" . ,(princ-to-string (* (if buyp 1 -1) size)))
                  ("execInst" . "ParticipateDoNotInitiate"))))

(defmethod post-offer ((gate bitmex-gate) offer)
  (with-slots (market volume price) offer
    (let ((factor (expt 10 (decimals market))))
      (with-json-slots ((oid "orderID") (status "ordStatus") text)
          (post-raw-limit gate (not (plusp price)) (name market)
                          (multiple-value-bind (int dec)
                              (floor (abs price) factor)
                            (format nil "~D.~V,'0D"
                                    int (decimals market) dec))
                          (floor (* volume (if (minusp price) 1
                                               (/ price factor)))))
        (if (equal status "New") (change-class offer 'placed :oid oid)
            (unless (search "ParticipateDoNotInitiate" text)
              (warn "Failed placing: ~S~%~A" offer text)))))))

(defmethod cancel-offer ((gate bitmex-gate) (offer placed))
  (multiple-value-bind (ret err)
      (gate-request gate '(:delete "order") `(("orderID" . ,(oid offer))))
    (or (member (getjso "ordStatus" (car ret))
                '("Canceled" "Filled") :test #'equal)
        (equal (getjso "message" err) "Not Found"))))
