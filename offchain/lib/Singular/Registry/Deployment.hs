{- |
Module      : Singular.Registry.Deployment
Description : One persistent registry, recorded and re-attached to
License     : Apache-2.0

A runner boots its own registry and publishes its own reference scripts
on every run. On a private devnet that is free and right. On a public
network it means every run pays to publish the same scripts again and
creates a registry nothing else will ever look at — a demonstration of
the code rather than of a deployment.

This module is the other half: a __deployment manifest__ recording one
registry booted once and one set of reference-script outputs published
once, and the means to attach a later run to them. It is the facade the
caller imports; the definitions live in the three focused owners behind
it — "Singular.Registry.Deployment.Manifest" for the manifest, its JSON
and the paths around it, "Singular.Registry.Deployment.Mirror" for the
proof mirror persisted beside it, and
"Singular.Registry.Deployment.Attach" for the node decisions. See the
deployment ownership guide for who owns what and which way the
dependencies run.

Three operations:

* __record__ — the @deploy@ command writes the manifest after booting
and publishing ('writeDeployment').
* __check__ — 'verifyDeployment' asks a node whether it still agrees:
every reference output is live and carries the hash the manifest
pins, the registry's state output carries the recorded token, and the
release in hand compiles to the hashes the manifest was made with.
* __attach__ — 'attach' rebuilds the cage configuration from the
manifest and resolves the reference outputs and the state output, so a
run uses them instead of creating its own.

__What the manifest cannot carry.__ Writing to a registry — folding a
claim in — means proving the key against the registry's current trie,
and that proof needs the whole trie, not the root the chain reports.
Nothing on chain hands it over in one query, so a deployment carries it
as a file beside the manifest ('mirrorPathFor'), written by each run
and read by the next.

That file is the deployment's one non-chain dependency: a second
machine needs a copy of it to fold, though not to read — proving a name
is alive needs the registry entry and the NFT, and no trie at all.
Rebuilding the trie from the chain instead, by following the registry
token from the bootstrap transaction and replaying each fold's request
datums, is the next milestone's work.

That file is a hazard, so it is checked rather than hoped away — by the
caller that attaches, not by 'attach' itself: after attaching, the
retained journey callers compare the loaded mirror's root with the
chain's root, so a mirror that drifted (a run that died mid-fold, a copy
belonging to another deployment) fails by name instead of building
proofs against a trie the chain does not have.
-}
module Singular.Registry.Deployment
    ( -- * The manifest
      Deployment (..)
    , ReferenceScript (..)
    , readDeployment
    , writeDeployment

      -- * Choosing one
    , deploymentPathFromArgs
    , deploymentPathFromEnvironment

      -- * The release halves the manifest pins only by hash
    , CageParts (..)
    , cageConfigFor

      -- * Checking one against a node
    , verifyDeployment

      -- * Attaching a run to one
    , Attached (..)
    , attach

      -- * The proof mirror beside the manifest
    , mirrorPathFor
    , loadMirror
    , saveMirror

      -- * Output references
    , renderOutRef
    , parseOutRef
    , renderAddrBytes
    ) where

import Singular.Registry.Deployment.Attach
    ( Attached (..)
    , CageParts (..)
    , attach
    , cageConfigFor
    , verifyDeployment
    )
import Singular.Registry.Deployment.Manifest
    ( Deployment (..)
    , ReferenceScript (..)
    , deploymentPathFromArgs
    , deploymentPathFromEnvironment
    , mirrorPathFor
    , parseOutRef
    , readDeployment
    , renderAddrBytes
    , renderOutRef
    , writeDeployment
    )
import Singular.Registry.Deployment.Mirror
    ( loadMirror
    , saveMirror
    )
