{- |
Module      : Singular.CLI.Key
Description : The registry key a command names, read from its spelling
License     : Apache-2.0

A caller names a key once, by `--key` (text, its UTF-8 bytes) or
`--key-hex` (base16). This module reads the three that arrive as text —
key only; deposit and payload are application inputs — each refusing its
bad input under a name of its own. Both binaries read keys through this
one module, so no command keeps a decoder of its own.
-}
module Singular.CLI.Key
    ( -- * Readers
      KeyEncoding (..)
    , KeyRefusal (..)
    , maxKeyBytes
    , readKey
    , keyFlags
    ) where

import Control.Monad (when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

-- | How a key argument spells its bytes.
data KeyEncoding
    = -- | the UTF-8 bytes of the text
      KeyText
    | -- | base16
      KeyHex
    deriving stock (Eq, Show)

-- | Why a key argument is refused.
data KeyRefusal
    = KeyEmpty
    | KeyNotHex
    | -- | the byte length it came to
      KeyTooLong Int
    deriving stock (Eq, Show)

-- | The longest key, in bytes.
maxKeyBytes :: Int
maxKeyBytes = 32

-- | The key bytes an argument spells under the chosen encoding.
readKey :: KeyEncoding -> Text -> Either KeyRefusal ByteString
readKey encoding argument = do
    spelled <- case encoding of
        KeyText -> Right (TE.encodeUtf8 argument)
        KeyHex -> first (const KeyNotHex) (B16.decode (TE.encodeUtf8 argument))
    when (BS.null spelled) $ Left KeyEmpty
    let size = BS.length spelled
    when (size > maxKeyBytes) $ Left (KeyTooLong size)
    pure spelled

{- | The flags that spell a registry key, each with how it spells it: the one set
the key reader and every command that refuses a key are derived from.
-}
keyFlags :: [(String, KeyEncoding)]
keyFlags = [("--key", KeyText), ("--key-hex", KeyHex)]
