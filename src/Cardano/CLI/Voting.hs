{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Cardano.CLI.Voting where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Except (MonadError)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.String (fromString)
import qualified Data.ByteString.Base16 as Base16

import Cardano.API (TxMetadata, SigningKey, StakeKey, LocalNodeConnectInfo, Address, TTL, TxBody, Lovelace(Lovelace), TxIn, PaymentKey, Tx, serialiseToRawBytesHex, serialiseToRawBytes, getVerificationKey, makeTransactionMetadata, localNodeNetworkId, NetworkId, Key, AsType(AsPaymentKey, AsStakeKey), VerificationKey, PaymentCredential, StakeCredential, StakeAddressReference, makeShelleyTransaction, txExtraContentEmpty, makeShelleyKeyWitness, makeSignedTransaction, TxIn(TxIn), verificationKeyHash, makeShelleyAddress, estimateTransactionFee, deserialiseFromRawBytesHex)
import Cardano.Api.LocalChainSync ( getLocalTip )
import Ouroboros.Network.Point (fromWithOrigin)
import Ouroboros.Network.Block (getTipSlotNo)
import           Shelley.Spec.Ledger.PParams (PParams)
import Cardano.Api.Typed (Shelley, txCertificates, txWithdrawals, txMetadata, txUpdateProposal, TxMetadataValue(TxMetaNumber, TxMetaMap, TxMetaText, TxMetaBytes), StandardShelley, TxOut(TxOut), ShelleyWitnessSigningKey(WitnessPaymentKey), TxId(TxId), TxIx(TxIx), deterministicSigningKey, deterministicSigningKeySeedSize, PaymentCredential(PaymentCredentialByKey), StakeCredential(StakeCredentialByKey), StakeAddressReference(StakeAddressByValue), AsType(AsSigningKey))
import qualified Shelley.Spec.Ledger.UTxO as Ledger
import qualified Shelley.Spec.Ledger.Tx as Ledger
import qualified Shelley.Spec.Ledger.Coin as Ledger
import qualified Shelley.Spec.Ledger.PParams as Shelley
import Cardano.CLI.Types (QueryFilter(NoFilter, FilterByAddress))
import Ouroboros.Network.Util.ShowProxy (ShowProxy)
import Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr, GenTx)
import Ouroboros.Consensus.Cardano.Block (Query)
import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Seed as Crypto
import qualified Cardano.Binary as CBOR
import Ouroboros.Network.Protocol.LocalStateQuery.Type (ShowQuery)

import Cardano.API.Extended (textEnvelopeToJSON)
import CLI.Jormungandr (jcliKeyFromBytes, jcliSign, jcliValidateSig)
import Cardano.API.Voting (VotingKeyPublic, deserialiseFromBech32, AsType(AsVotingKeyPublic))
import Cardano.API.Extended (AsShelleyQueryCmdLocalStateQueryError, queryPParamsFromLocalState, queryUTxOFromLocalState)
import Encoding (AsDecodeError, AsBech32DecodeError, bech32SignatureToBytes, newPrefix, AsBech32HumanReadablePartError )
import Cardano.CLI.Voting.Error
import Cardano.CLI.Voting.Fee
import Cardano.CLI.Voting.Metadata (Vote, VotePayload, mkVotePayload, signVotePayload, voteMetadata)

import Data.Word

prettyTx :: Tx Shelley -> String
prettyTx = BSC.unpack . textEnvelopeToJSON Nothing

harn
  :: ( MonadIO m
     , MonadError e m
     , AsDecodeError e
     , AsBech32DecodeError e
     , AsBech32HumanReadablePartError e
     )
  => m Vote
harn = do
  stkSign   <- maybe (error "Failed to deserialise stake signing key") pure $
    deserialiseFromRawBytesHex (AsSigningKey AsStakeKey) "efb3df51bee6858af75927ce0f4828e55876d8c3111831f87ca4058b7da58a69"
  votePub   <- either (error . show) pure $
    deserialiseFromBech32 AsVotingKeyPublic "ed25519e_sk1cpxudluugmp8wgl2jrl0hcatlgmgzhwte8cguhqjmq642gzytf3mj05q5f8etx8pv47qadxvsgxjj2pygtf4xglu3emspqt95drxpwg9wqqr4"

  createVote stkSign votePub

createVote
  :: ( MonadIO m
     , MonadError e m
     , AsDecodeError e
     , AsBech32DecodeError e
     , AsBech32HumanReadablePartError e
     )
  => SigningKey StakeKey
  -> VotingKeyPublic
  -> m Vote
createVote stkSign votepub = do
  jcliStkSign   <- jcliKeyFromBytes (serialiseToRawBytesHex stkSign)
  let stkVerifyBytes = serialiseToRawBytes (getVerificationKey stkSign)

  let
    payload = mkVotePayload votepub (getVerificationKey stkSign)

    payloadCBOR = CBOR.serialize' payload

  sigBytes <- bech32SignatureToBytes =<< jcliSign jcliStkSign payloadCBOR

  x <- newPrefix "ed25519_pk" stkVerifyBytes
  y <- newPrefix "ed25519_sig" sigBytes
  jcliValidateSig x y payloadCBOR

  pure $ signVotePayload payload sigBytes

encodeVote
  :: ( MonadIO m
     , MonadError e m
     , AsShelleyQueryCmdLocalStateQueryError e

     , ShowProxy block
     , ShowProxy (ApplyTxErr block)
     , ShowProxy (Query block)
     , ShowProxy (GenTx block)
     , ShowQuery (Query block)
     )
  => LocalNodeConnectInfo mode block
  -> Address Shelley
  -> TTL
  -> Vote
  -> m (TxBody Shelley)
encodeVote connectInfo addr ttl vote = do
  -- Get the network parameters
  pparams <- queryPParamsFromLocalState connectInfo
  let
    meta      = voteMetadata vote
    networkId = localNodeNetworkId connectInfo

  -- Estimate the fee for the transaction
  let
    feeParams = estimateVoteFeeParams networkId pparams meta

  -- Find some unspent funds
  utxos <- queryUTxOFromLocalState (FilterByAddress $ Set.singleton addr) connectInfo
  case findUnspent feeParams (fromShelleyUTxO utxos) of
    Nothing      -> undefined
    Just unspent -> do
      tip <- liftIO $ getLocalTip connectInfo
      let
        slotTip          = fromWithOrigin minBound $ getTipSlotNo tip
        txins            = unspentSources unspent 
        (Lovelace value) = unspentValue unspent
        (Lovelace fee)   =
          estimateVoteTxFee
            networkId pparams slotTip txins addr (Lovelace value) meta

      -- Create the vote transaction
      pure $ voteTx addr txins (Lovelace $ value - fee) (slotTip + ttl) (Lovelace fee) meta

voteTx
  :: Address Shelley
  -> [TxIn]
  -> Lovelace
  -> TTL
  -> Lovelace
  -> TxMetadata
  -> TxBody Shelley
voteTx addr txins (Lovelace value) ttl (Lovelace fee) meta =
 let
   txouts = [TxOut addr (Lovelace $ value - fee)]
 in
   makeShelleyTransaction txExtraContentEmpty {
                            txCertificates   = [],
                            txWithdrawals    = [],
                            txMetadata       = Just meta,
                            txUpdateProposal = Nothing
                          }
                          ttl
                          (Lovelace fee)
                          txins
                          txouts

signTx :: SigningKey PaymentKey -> TxBody Shelley -> Tx Shelley
signTx psk txbody =
  let
    witness = makeShelleyKeyWitness txbody (WitnessPaymentKey psk)
  in
    makeSignedTransaction [witness] txbody

fromShelleyUTxO :: Ledger.UTxO StandardShelley -> UnspentSources
fromShelleyUTxO = fmap convert . M.assocs . Ledger.unUTxO
  where
    convert :: (Ledger.TxIn StandardShelley, Ledger.TxOut StandardShelley) -> (TxIn, Lovelace)
    convert (txin, Ledger.TxOut _ (Ledger.Coin value)) = (fromShelleyTxIn txin, Lovelace value)

fromShelleyTxIn  :: Ledger.TxIn StandardShelley -> TxIn
fromShelleyTxIn (Ledger.TxIn txid txix) =
    TxIn (fromShelleyTxId txid) (TxIx (fromIntegral txix))

fromShelleyTxId :: Ledger.TxId StandardShelley -> TxId
fromShelleyTxId (Ledger.TxId h) =
    TxId (Crypto.castHash h)
