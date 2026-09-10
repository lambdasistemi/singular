-- | The t45 wire-vector suite: asserts the naming codec against the
-- vendored epic-15 v0.2.0 vectors byte for byte, including the negative
-- cases the vectors record. Plain base + bytestring, so the suite runs
-- with the dev-shell GHC alone — no package index, no network.
module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (isNothing)
import System.Exit (exitFailure)

import Naming.Datum
    ( decodeNamingDatum
    , deserialiseNamingDatum
    , encodeNamingDatum
    , extractNamingDatum
    , namingDatumShape
    , serialiseNamingDatum
    )
import Naming.Request
    ( RefundComparison (..)
    , compareRefund
    , deserialiseInsertCommitment
    , encodeInsertCommitment
    , insertRequestShape
    , matchingInsertCommitment
    , serialiseInsertCommitment
    )
import Naming.Wire
    ( deserialiseWireData
    , serialiseWireData
    )
import Naming.Wire.Vectors

-- | A check: 'Nothing' passes, @Just reason@ fails with that reason.
type Check = IO (Maybe String)

main :: IO ()
main = do
  outcomes <- mapM runCheck checks
  let total = length outcomes
      failed = length (filter not outcomes)
  if failed == 0
    then
      putStrLn $
        "ALL-VECTORS PASS: " ++ show total ++ " checks over 4 vectors"
          ++ " (WD01 WD02 WD03 WR01),"
          ++ " byte comparisons byte-for-byte against expectedBytes"
    else do
      putStrLn ("SUITE FAILED: " ++ show failed ++ " of " ++ show total ++ " checks")
      exitFailure

runCheck :: (String, Check) -> IO Bool
runCheck (name, check) = do
  result <- check
  case result of
    Nothing -> do
      putStrLn ("PASS  " ++ name)
      pure True
    Just reason -> do
      putStrLn ("FAIL  " ++ name)
      putStrLn ("      " ++ reason)
      pure False

checks :: [(String, Check)]
checks =
  [ ( wd01Id ++ ": encode(fixture) == expectedBytes, byte-for-byte"
    , pure $
        case serialiseNamingDatum wd01Fixture of
          Nothing -> Just "the encoder refused the WD01 fixture"
          Just bytes ->
            expectBytesEqual "encode(fixture) != expectedBytes" bytes wd01ExpectedBytes
    )
  , ( wd01Id ++ ": decode(expectedBytes) == decoded fixture"
    , pure $
        case deserialiseNamingDatum wd01ExpectedBytes of
          Nothing -> Just "decode(expectedBytes) produced nothing"
          Just datum
            | datum == wd01Fixture -> Nothing
            | otherwise -> Just "decode(expectedBytes) != the recorded decoded fixture"
    )
  , ( wd01Id ++ ": re-encoding the decoded datum reproduces expectedBytes"
    , pure $
        case deserialiseNamingDatum wd01ExpectedBytes of
          Nothing -> Just "decode(expectedBytes) produced nothing"
          Just datum ->
            expectBytesEqual
              "re-encoded bytes != expectedBytes"
              (maybe mempty id (serialiseNamingDatum datum))
              wd01ExpectedBytes
    )
  , ( wd01Id ++ ": decode(malformedBytes) is nothing (malformedResult: null)"
    , pure $
        if isNothing (deserialiseNamingDatum wd01MalformedBytes)
          then Nothing
          else
            Just
              "the malformed input decoded successfully, but the vector records malformedResult: null"
    )
  , ( wd01Id ++ ": shape == {arity: 4, innerIndex: 0, outerIndex: 0}"
    , pure $
        case namingDatumShape (encodeNamingDatum wd01Fixture) of
          Just shape | shape == wd01Shape -> shapeOfBytesCheck
          _ -> Just "the encoded datum's shape != {arity: 4, innerIndex: 0, outerIndex: 0}"
    )
  , ( wd02Id ++ ": a datum-hash attachment is refused (result: null)"
    , pure $
        if isNothing (extractNamingDatum wd02Attachment)
          then Nothing
          else
            Just "an attached datum hash decoded, but the vector records result: null"
    )
  , ( wd03Id ++ ": decodeNamingDatum(two-destination datum) is nothing (result: null)"
    , pure $
        if isNothing (decodeNamingDatum wd03Encoded)
          then Nothing
          else
            Just
              "the two-destination datum decoded, but the vector records result: null"
    )
  , ( wd03Id ++ ": deserialise+decode of the serialised two-destination datum is nothing"
    , pure $
        case serialiseWireData wd03Encoded of
          Nothing -> Just "the two-destination datum did not serialise"
          Just bytes
            | isNothing (deserialiseNamingDatum bytes) -> Nothing
            | otherwise -> Just "the serialised two-destination datum decoded"
    )
  , ( wr01Id ++ ": encode(stored proposal commitment) == expectedBytes, byte-for-byte"
    , pure $
        case serialiseInsertCommitment wr01StoredProposal of
          Nothing -> Just "the encoder refused the stored proposal"
          Just bytes ->
            expectBytesEqual
              "encode(stored commitment) != expectedBytes"
              bytes
              wr01ExpectedBytes
    )
  , ( wr01Id ++ ": decode(expectedBytes) == stored proposal (refundAddress 60 round-trips)"
    , pure $
        case deserialiseInsertCommitment wr01ExpectedBytes of
          Nothing -> Just "decode(expectedBytes) produced nothing"
          Just proposal
            | proposal == wr01StoredProposal -> Nothing
            | otherwise -> Just "decode(expectedBytes) != the stored proposal"
    )
  , ( wr01Id ++ ": re-encoding the decoded commitment reproduces expectedBytes"
    , pure $
        case deserialiseInsertCommitment wr01ExpectedBytes of
          Nothing -> Just "decode(expectedBytes) produced nothing"
          Just proposal ->
            expectBytesEqual
              "re-encoded bytes != expectedBytes"
              (maybe mempty id (serialiseInsertCommitment proposal))
              wr01ExpectedBytes
    )
  , ( wr01Id ++ ": decode(malformedBytes) is nothing (malformedResult: null)"
    , pure $
        if isNothing (deserialiseInsertCommitment wr01MalformedBytes)
          then Nothing
          else
            Just
              "the malformed input decoded successfully, but the vector records malformedResult: null"
    )
  , ( wr01Id ++ ": shape == {commitmentIndex: 0, commitmentArity: 1, proposalIndex: 0, proposalArity: 6}"
    , pure $
        case insertRequestShape (encodeInsertCommitment wr01StoredProposal) of
          Just shape | shape == wr01Shape -> Nothing
          _ ->
            Just
              "shape != {commitmentIndex: 0, commitmentArity: 1, proposalIndex: 0, proposalArity: 6}"
    )
  , ( wr01Id ++ ": redirectedBytes decodes to the redirected proposal (refundAddress 61)"
    , pure $
        case deserialiseInsertCommitment wr01RedirectedBytes of
          Just proposal
            | proposal == wr01RedirectedProposal -> Nothing
          _ -> Just "redirectedBytes did not decode to the refund-61 proposal"
    )
  , ( wr01Id ++ ": the redirected refund compares unequal to the stored one"
    , pure $
        if wr01RedirectedProposal /= wr01StoredProposal
          then Nothing
          else Just "the redirected proposal equals the stored proposal"
    )
  , ( wr01Id
        ++ ": matching the redirected commitment against the request is refused"
        ++ " (redirectedRequestResult: null)"
    , pure $
        if isNothing (matchingInsertCommitment wr01StoredProposal wr01RedirectedBytes)
          then Nothing
          else Just "the redirected commitment matched the request"
    )
  , ( wr01Id
        ++ ": compareRefund(stored, presented) refuses with withdraw-refund-address"
        ++ " (comparisonResult), the stored refund itself accepted"
    , pure $
        if compareRefund wr01StoredRefundAddress wr01PresentedRefundAddress
          == wr01ComparisonResult
          then case compareRefund wr01StoredRefundAddress wr01StoredRefundAddress of
            RefundAccepted -> Nothing
            _ -> Just "the stored refund itself was not accepted"
          else
            Just
              "compareRefund(60, 61) did not refuse with withdraw-refund-address"
    )
  ]
  where
    shapeOfBytesCheck = case deserialiseWireData wd01ExpectedBytes of
      Just wire
        | Just shape <- namingDatumShape wire
        , shape == wd01Shape ->
            Nothing
      _ -> Just "the shape of the bytes behind expectedBytes != the recorded shape"

expectBytesEqual :: String -> ByteString -> ByteString -> Maybe String
expectBytesEqual what got expected
  | got == expected = Nothing
  | otherwise = Just (what ++ ": " ++ difference)
  where
    difference
      | BS.length got /= BS.length expected =
          "length "
            ++ show (BS.length got)
            ++ " != expected length "
            ++ show (BS.length expected)
            ++ "; first difference at byte index "
            ++ show index
            ++ gotAt
      | otherwise =
          "byte index "
            ++ show index
            ++ " differs: got "
            ++ hex (BS.index got index)
            ++ ", expected "
            ++ hex (BS.index expected index)
    gotAt
      | index < BS.length got = " (got " ++ hex (BS.index got index) ++ ")"
      | otherwise = ""
    index = firstMismatch 0
    firstMismatch n
      | n >= BS.length got || n >= BS.length expected = n
      | BS.index got n /= BS.index expected n = n
      | otherwise = firstMismatch (n + 1)
    hex w = "0x" ++ [digit (w `div` 16), digit (w `mod` 16)]
    digit d
      | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral d - 10)
