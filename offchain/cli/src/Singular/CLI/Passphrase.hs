{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Passphrase
Description : Reading a wallet passphrase from a terminal or a descriptor
License     : Apache-2.0

A passphrase is a non-empty byte string held in memory for the length of
one command. It has no textual rendering that shows its content: the
'Show' instance prints a fixed marker, and no refusal names it.

Two sources, one parser:

* a terminal prompt on @\/dev\/tty@ with echo disabled — a human typing;
* an inherited file descriptor (@--passphrase-fd N@) reading one line —
  a script. The descriptor source never asks for a confirmation, so a
  scripted creation reads the passphrase exactly once.

The passphrase is never accepted as a command-line argument, an
environment variable or a file path; the command layer owns that
boundary and passes a 'PassphraseSource' here.
-}
module Singular.CLI.Passphrase
    ( Passphrase
    , mkPassphrase
    , passphraseBytes
    , confirmPassphrase
    , PassphraseSource (..)
    , Confirmation (..)
    , PassphraseRefusal (..)
    , renderPassphraseRefusal
    , readPassphrase
    , readHiddenLine
    , withHiddenEcho
    ) where

import Control.Exception
    ( IOException
    , bracket
    , bracket_
    , catch
    )
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Functor ((<&>))
import System.IO
    ( BufferMode (NoBuffering)
    , Handle
    , hClose
    , hFlush
    , hPutStr
    , hSetBuffering
    )
import System.Posix.IO
    ( OpenMode (ReadWrite)
    , defaultFileFlags
    , fdToHandle
    , openFd
    )
import System.Posix.Terminal
    ( TerminalMode (EnableEcho)
    , TerminalState (Immediately)
    , getTerminalAttributes
    , setTerminalAttributes
    , withoutMode
    )
import System.Posix.Types (Fd (..))

-- | A non-empty passphrase, compared by content and never shown.
newtype Passphrase = Passphrase ByteString
    deriving stock (Eq)

instance Show Passphrase where
    show _ = "<passphrase>"

{- | The one place a passphrase is born from bytes: empty is refused,
everything else is kept, byte for byte. No length cap is imposed —
scrypt's work factor, not the passphrase length, bounds the cost of
opening a vault. Readers trim their line ending before this; the
passphrase itself is never normalized.
-}
mkPassphrase :: ByteString -> Either PassphraseRefusal Passphrase
mkPassphrase raw
    | BC.null raw = Left PassphraseEmpty
    | otherwise = Right (Passphrase raw)

{- | The passphrase's bytes, read by the vault's seal and open only;
no rendering of them exists anywhere.
-}
passphraseBytes :: Passphrase -> ByteString
passphraseBytes (Passphrase bytes) = bytes

{- | The confirmation decision of an interactive creation, pure so the
mismatch rule is checkable without a terminal: two typed lines that
disagree are the mismatch refusal; two that agree are a passphrase, so
an agreeing empty pair is the empty refusal, not a passphrase.
-}
confirmPassphrase
    :: ByteString -> ByteString -> Either PassphraseRefusal Passphrase
confirmPassphrase first second
    | first /= second = Left PassphraseConfirmationDiffers
    | otherwise = mkPassphrase first

-- | Where a passphrase is read from: the terminal, or a descriptor.
data PassphraseSource
    = -- | @\/dev\/tty@, echo disabled, the human path
      PassphraseTerminal
    | -- | an inherited file descriptor, @--passphrase-fd N@, the script path
      PassphraseDescriptor Int

-- | Whether a terminal read asks for the passphrase twice.
data Confirmation
    = -- | read the passphrase once (an opening command)
      AskOnce
    | -- | read it twice and require agreement (a creation command)
      AskTwice

-- | Why a passphrase could not be read. None names the passphrase.
data PassphraseRefusal
    = -- | the passphrase itself is empty
      PassphraseEmpty
    | -- | the two typed lines disagreed
      PassphraseConfirmationDiffers
    | -- | the given descriptor could not be read, naming its number
      PassphraseDescriptorUnreadable Int
    | -- | @\/dev\/tty@ could not be opened or read
      PassphraseTerminalUnavailable
    deriving stock (Eq, Show)

-- | One line naming the refusal, carrying no secret.
renderPassphraseRefusal :: PassphraseRefusal -> String
renderPassphraseRefusal = \case
    PassphraseEmpty -> "the passphrase is empty"
    PassphraseConfirmationDiffers -> "the passphrase confirmation did not match"
    PassphraseDescriptorUnreadable n ->
        "cannot read the passphrase from descriptor " <> show n
    PassphraseTerminalUnavailable -> "cannot read a passphrase from the terminal"

{- | Read a passphrase from the source. A terminal source honours the
confirmation; a descriptor source reads exactly one line whatever the
confirmation asks, so a scripted creation is never asked twice. The one
line read is trimmed of its line ending only.
-}
readPassphrase
    :: Confirmation
    -> PassphraseSource
    -> IO (Either PassphraseRefusal Passphrase)
readPassphrase confirmation = \case
    PassphraseDescriptor n ->
        readDescriptorLine n <&> (>>= mkPassphrase . trimLine)
    PassphraseTerminal -> case confirmation of
        AskOnce ->
            readTerminalLine "Vault passphrase: "
                <&> (>>= mkPassphrase . trimLine)
        AskTwice -> do
            first <- readTerminalLine "New vault passphrase: "
            case first of
                Left refusal -> pure (Left refusal)
                Right bytes -> do
                    second <- readTerminalLine "Confirm vault passphrase: "
                    pure
                        ( second
                            >>= \second' ->
                                confirmPassphrase (trimLine bytes) (trimLine second')
                        )

-- | One line from an inherited descriptor, or the refusal naming it.
readDescriptorLine :: Int -> IO (Either PassphraseRefusal ByteString)
readDescriptorLine n =
    catch
        ( bracket
            (fdToHandle (Fd (fromIntegral n)))
            hClose
            (fmap Right . BC.hGetLine)
        )
        (\(_ :: IOException) -> pure (Left (PassphraseDescriptorUnreadable n)))

{- | One line from @\/dev\/tty@ with echo disabled, restored whatever
happens. The prompt is printed before the echo is turned off, so the
typed characters never appear.
-}
readTerminalLine :: String -> IO (Either PassphraseRefusal ByteString)
readTerminalLine prompt =
    catch
        ( bracket
            openTerminal
            (hClose . snd)
            (uncurry (readHiddenLine prompt))
        )
        (\(_ :: IOException) -> pure (Left PassphraseTerminalUnavailable))

-- | @\/dev\/tty@ read and written without buffering, with its fd.
openTerminal :: IO (Fd, Handle)
openTerminal = do
    fd <- openFd "/dev/tty" ReadWrite defaultFileFlags
    handle <- fdToHandle fd
    hSetBuffering handle NoBuffering
    pure (fd, handle)

{- | The hidden terminal's bracket: the echo is turned off before the
bracketed action runs — so no byte the action writes, the prompt first
among them, can reach a terminal whose echo is still on — and restored
on every exit, the action throwing included. The read is the caller's,
supplied as an argument, so the ordering and the restoration are
provable without tearing a terminal down.
-}
withHiddenEcho :: Fd -> IO a -> IO a
withHiddenEcho fd action = do
    attributes <- getTerminalAttributes fd
    let hidden = withoutMode attributes EnableEcho
    bracket_
        (setTerminalAttributes fd hidden Immediately)
        (setTerminalAttributes fd attributes Immediately)
        action

{- | Print the prompt and read the echo-less line on a terminal this
caller opened, inside 'withHiddenEcho': the echo is off before the
prompt's first byte is written, and restored on every exit. The
newline printed after the line is the prompt's own, never the typed
text.
-}
readHiddenLine
    :: String -> Fd -> Handle -> IO (Either PassphraseRefusal ByteString)
readHiddenLine prompt fd handle = do
    line <-
        withHiddenEcho fd $ do
            hPutStr handle prompt
            hFlush handle
            BC.hGetLine handle
    hPutStr handle "\n"
    hFlush handle
    pure (Right line)

-- | One line as typed: its trailing carriage return and line feed gone.
trimLine :: ByteString -> ByteString
trimLine = BC.dropWhileEnd (\c -> c == '\r' || c == '\n')
