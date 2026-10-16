# Data for submitting a bundle

## Chain status of a transaction

Either found, with a chain point (slot and block hash) and a confirmation count, or not found. Nothing else: no inference from outputs.

## Plan

An ordered list of steps, one per bundle transaction: send, or found on chain. Built only when every check passed.

## Needed keys

For each transaction still to send, the set of payment key hashes needing a witness: its required signers, plus the payment key hashes of its input and collateral outputs. A script credential adds nothing.

## Receipt

Command name, outcome class, bundle hash, and per transaction: identity, how it got there (sent by this run, or found), chain point, confirmations and outputs as read from the chain after the run, and the bundle's effect lines under a field named as claims.

## Refusal

Named refusals, each carrying what it concerns and nothing secret: witness unreadable, witness for a different body, witness for a key nobody needs, needed witness missing, expired body (rebuild), unresolved input, bundle problems of the signing step, uncertain submission, provider failure.
