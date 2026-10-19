{- |
Module      : Singular.CLI.Version
Description : The release and commit a packaged command was built from
License     : Apache-2.0

Every packaged command states the release it belongs to and the commit it
was built from, in the identity line @--version@ and every help page open
with: @program 0.12.0 (commit 60f59f97...)@. The release number is the
package version, compiled in, with the fourth component dropped (the Cabal
version of a release is its release number followed by @.0@). The commit is
not known to the Haskell build, which the commit must not invalidate: the
executable carries a fixed-width slot, and the Nix packaging overwrites the
slot's payload in a copy of the built executable. The commands read the
stamped commit as the identity line's commit variable; a build nobody
stamped, such as a bare @cabal build@, reads the slot as @unknown@ and leaves
the variable to the environment.
-}
module Singular.CLI.Version
    ( releaseVersion
    , stampedEnvironment
    , builtCommit
    , commitFromSlot
    , commitSlot
    ) where

import Data.Version (Version, makeVersion, versionBranch)

import Singular.CLI.Options (releaseCommitVariable)

{- | The slot the Nix packaging stamps: a fixed marker, then a payload of 64
bytes, @unknown@ padded with @#@ until stamped, the commit padded with @#@
after. Its width never changes, so the executable's size and layout do not.
-}
commitSlot :: String
commitSlot =
    "SINGULAR-COMMIT-SLOT-V1:unknown#########################################################"
{-# NOINLINE commitSlot #-}

{- | The commit a slot states: its payload up to the padding, or @unknown@
when the payload is empty.
-}
commitFromSlot :: String -> String
commitFromSlot slot = case takeWhile (/= '#') (drop (length marker) slot) of
    "" -> "unknown"
    commit -> commit
  where
    marker :: String
    marker = "SINGULAR-COMMIT-SLOT-V1:"

-- | The commit stamped into this executable, or @unknown@.
builtCommit :: String
builtCommit = commitFromSlot commitSlot

{- | The release version of a package version: its first three components
(the PVP fourth component of a release is always @0@).
-}
releaseVersion :: Version -> Version
releaseVersion = makeVersion . take 3 . versionBranch

{- | The environment the identity line reads, with the commit an executable
was stamped with. A stamped commit wins over the variable, so a person's
environment cannot make a release say another commit; an unstamped
executable leaves the environment as it is.
-}
stampedEnvironment
    :: String -> [(String, String)] -> [(String, String)]
stampedEnvironment "unknown" environment = environment
stampedEnvironment commit environment =
    (releaseCommitVariable, commit)
        : filter ((/= releaseCommitVariable) . fst) environment
