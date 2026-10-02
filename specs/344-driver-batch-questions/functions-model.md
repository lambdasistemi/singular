# Declare the batch questions

As a caller, I want two new driver entry points and unchanged existing ones.

## Interface contract

The driver gains one entry point per question, each taking the starting state, the setup trace and the request list, returning the driver's existing result shape; the reject question's judgement takes the observed outputs. Names are the coder's choice in the driver's vocabulary, recorded in the PR. The two preservation statements are theorems: one over `foldBatch` and `step` with the lawful-claim hypothesis, one over the reject batch judgement and the single reject judgement.

`runSurface`, `judgeSurface`, `admittedExitStep`, every `Singular.Model` definition and the single-request transport question keep their signatures and answers.
