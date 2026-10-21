{- |
Module      : Singular.CLI.Payload
Description : The one place a payload file is read for a command
License     : Apache-2.0

Every command that takes @--payload@ reads the file here (#719): the file
as JSON, then under the payload schema the command was given. A refusal is
a client refusal that names the file and the flag, raised before any node
is read, in one of three sentences:

* the file is not JSON: the file, then the JSON reader's reason;
* the schema is detailed and the file is not Plutus data: the file,
  @--payload is not Plutus data@, then the reason the previous release gave;
* the schema is plain and the file cannot be stored: the file,
  @--payload cannot be stored as plain JSON@, then the value that cannot
  and where it is, or the instruction for a file in the detailed schema.
-}
module Singular.CLI.Payload
    ( readPayloadFile
    ) where

import Data.Text qualified as T
import PlutusCore.Data qualified as PLC

import Singular.CLI.Plan (readJson)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith)
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , payloadFromJson
    )

{- | The payload a file holds, under the schema the command was given. Any
failure is a client refusal naming the file.
-}
readPayloadFile :: PayloadSchema -> FilePath -> IO PLC.Data
readPayloadFile schema path =
    readJson path
        >>= either (failWith ClientRefusal . refused) pure
            . payloadFromJson schema
  where
    refused why = path <> ": --payload " <> verdict <> T.unpack why
    verdict = case schema of
        DetailedSchema -> "is not Plutus data: "
        PlainSchema -> "cannot be stored as plain JSON: "
