{- |
Module      : Deployment.Verify
Description : @deployment verify@ — does a node still agree with a manifest?
License     : Apache-2.0

Reads the manifest named by @--deployment@, binds the release's compiled
halves to the registry it records, asks the node claim by claim, and
prints each claim it answered, then how many held. Any claim the node
does not agree with is a refusal naming it.
-}
module Deployment.Verify
    ( verify
    ) where

import Deployment.Compiled (bindDeployment, loadCompiled)
import Deployment.Narration (emit)
import Deployment.Node (verifyRegisteredDeployment)
import Deployment.Options (verifyManifest)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (readDeployment)
import Singular.Registry.Runner (withRunner)

-- | Verify the manifest these arguments name against the node.
verify :: [String] -> IO ()
verify args = do
    path <- verifyManifest args
    dep <- readDeployment path
    compiled <- loadCompiled >>= (`bindDeployment` dep)
    withRunner $ \_wallet caps -> do
        claims <- verifyRegisteredDeployment (capReads caps) dep compiled
        mapM_ (emit "verified") claims
        emit
            "complete"
            (show (length claims) <> " claim(s) hold against this node")
