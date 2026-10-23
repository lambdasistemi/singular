{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Singular.Registry.TxBuilder.EdgesSurfaceSpec
Description : The library no longer offers the earlier law's edge booking
License     : Apache-2.0

A registration or a termination is a tagged request, booked through the
producers' tagged route. 'Singular.Registry.TxBuilder.Edges' once offered the
earlier law's booking as well: an untagged request carrying an approval. The
checkpoint that moved the hosted lanes onto the tagged law removes it once no
consumer is left.

The export list is read at compile time, through the module's own qualified
import, by name lookup. The row therefore compiles before and after that
removal and states the surface, not a source text: while a name is exported it
is found and the row fails; once it leaves, the lookup finds nothing and the
row holds.

The control that keeps the row from holding by looking in the wrong place
runs the same lookup for the names the module must keep offering (the duties
context the command line folds with, the deposit and the destination the
tagged producers read, and the publication of the reference outputs) and
requires every one to be found. The quoted names beside it make the compiler
check that each still exists.
-}
module Singular.Registry.TxBuilder.EdgesSurfaceSpec (spec) where

import Data.Maybe (catMaybes)
import Language.Haskell.TH (lookupValueName, nameBase)
import Language.Haskell.TH.Syntax (lift)
import Test.Hspec

import Singular.Registry.TxBuilder.Edges qualified as Edges

-- | The names of the earlier law's edge booking that the module still exports.
stillExported :: [String]
stillExported =
    $( do
        found <-
            mapM
                (\n -> fmap (const n) <$> lookupValueName ("Edges." <> n))
                [ "bookEdge"
                , "bookEdgeTo"
                , "bookEdgeWith"
                , "bookEdgeTx"
                , "bookEdgeMeasured"
                ]
        lift (catMaybes found)
     )

-- | The names the module must keep, found by the same lookup.
keptAndFound :: [String]
keptAndFound =
    $( do
        let keptNames =
                [ 'Edges.registryContextFor
                , 'Edges.edgeDeposit
                , 'Edges.edgeDestinationOf
                , 'Edges.publishCageRefs
                ]
        found <-
            mapM
                ( \name ->
                    fmap (const (nameBase name))
                        <$> lookupValueName ("Edges." <> nameBase name)
                )
                keptNames
        lift (catMaybes found)
     )

-- | The names the module must keep, as the compiler checked them.
kept :: [String]
kept =
    map
        nameBase
        [ 'Edges.registryContextFor
        , 'Edges.edgeDeposit
        , 'Edges.edgeDestinationOf
        , 'Edges.publishCageRefs
        ]

spec :: Spec
spec = describe "the library's booking surface" $ do
    it "finds, through the same lookup, every name the module must keep" $
        keptAndFound `shouldBe` kept
    it "exports none of the earlier law's edge booking" $
        stillExported `shouldBe` []
