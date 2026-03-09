;; Error codes
(define-constant ERR-ZERO-AMOUNT (err u100))
(define-constant ERR-INSUFFICIENT (err u101))
(define-constant ERR-NO-SHARES (err u102))
(define-constant ERR-TRANSFER-FAILED (err u110))

;; Persisted variables
(define-data-var fee-bps uint u100) 
(define-data-var admin principal tx-sender) 
(define-data-var total-deposits uint u0) 
(define-data-var total-shares uint u0) 

;; Fixed map definition to match usage
(define-map shares principal { amount: uint }) 

(define-public (compound (reward-amount uint))
  (begin
    (asserts! (> reward-amount u0) ERR-ZERO-AMOUNT)
    ;; transfer reward from caller -> contract
    (let ((transfer-result (stx-transfer? reward-amount tx-sender (as-contract tx-sender))))
      (match transfer-result
        success
          (let ((bps (var-get fee-bps))
                (fee (/ (* reward-amount bps) u10000))
                (net-reward (- reward-amount fee)))
            ;; Send fee to admin if greater than 0
            (if (> fee u0)
                (try! (as-contract (stx-transfer? fee (as-contract tx-sender) (var-get admin))))
                true
            )
            ;; Update vault totals
            (var-set total-deposits (+ (var-get total-deposits) net-reward))
            (ok { reward: reward-amount, fee: fee }))
        error ERR-TRANSFER-FAILED)))
)

;; Deposit STX and mint shares to caller.
(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    (match (stx-transfer? amount tx-sender (as-contract tx-sender))
      success
        (let (
          (ts (var-get total-shares)) 
          (td (var-get total-deposits))
          (share-amount (if (or (is-eq ts u0) (is-eq td u0))
                            amount
                            (/ (* amount ts) td)))
          (prev (default-to { amount: u0 } (map-get? shares tx-sender)))
        )
          (map-set shares tx-sender { amount: (+ (get amount prev) share-amount) })
          (var-set total-shares (+ ts share-amount))
          (var-set total-deposits (+ td amount))
          (ok { deposited: amount, shares-minted: share-amount })
        )
      error ERR-TRANSFER-FAILED
    )
  )
)

;; Withdraw by burning shares
(define-public (withdraw (share-amount uint))
  (begin
    (asserts! (> share-amount u0) ERR-ZERO-AMOUNT)
    (let ((user-data (unwrap! (map-get? shares tx-sender) ERR-NO-SHARES)))
      (let (
        (current-user-shares (get amount user-data))
        (td (var-get total-deposits))
        (ts (var-get total-shares))
        (underlying-amount (underlying-for-shares share-amount))
      )
        (asserts! (>= current-user-shares share-amount) ERR-INSUFFICIENT)
        
        ;; update state
        (map-set shares tx-sender { amount: (- current-user-shares share-amount) })
        (var-set total-shares (- ts share-amount))
        (var-set total-deposits (- td underlying-amount))
        
        ;; transfer STX from contract -> user
        (match (as-contract (stx-transfer? underlying-amount (as-contract tx-sender) tx-sender))
          transfer-success (ok { withdrawn: underlying-amount, remaining-shares: (- current-user-shares share-amount) })
          transfer-error ERR-TRANSFER-FAILED
        )
      )
    )
  )
)

;; -----------------------
;; Read-only functions
;; -----------------------

(define-read-only (calc-shares-for-deposit (amount uint))
  (let ((ts (var-get total-shares)) (td (var-get total-deposits)))
    (if (or (is-eq ts u0) (is-eq td u0))
        amount
        (/ (* amount ts) td)))
)

(define-read-only (calc-underlying-for-shares (share-amount uint))
  (underlying-for-shares share-amount)
)

(define-private (underlying-for-shares (share-amount uint))
  (let ((td (var-get total-deposits))
        (ts (var-get total-shares)))
    (if (or (is-eq ts u0) (is-eq td u0))
        share-amount
        (/ (* share-amount td) ts))))