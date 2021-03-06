module Kafka.Conduit.Sink
( module X
, kafkaSink, kafkaSinkAutoClose, kafkaSinkNoClose, kafkaBatchSinkNoClose
, commitOffsetsSink, flushThenCommitSink
) where

import           Control.Monad                (void)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Resource
import           Data.Conduit
import           Kafka.Consumer

import           Kafka.Conduit.Combinators    as X
import           Kafka.Consumer               as X (KafkaConsumer)
import           Kafka.Producer               as X


-- | Creates a Sink for a given `KafkaProducer`.
-- The producer will be closed when the Sink is closed.
kafkaSinkAutoClose :: MonadResource m
                   => KafkaProducer
                   -> Sink ProducerRecord m (Maybe KafkaError)
kafkaSinkAutoClose prod =
  bracketP (return prod) (void . closeProducer) runHandler
  where
    runHandler p' = do
      mbMsg <- await
      case mbMsg of
        Nothing -> return Nothing
        Just msg -> do
          res <- produceMessage p' msg
          case res of
            Nothing  -> runHandler p'
            Just err -> return (Just err)

-- | Creates a Sink for a given `KafkaProducer`.
-- The producer will NOT be closed automatically.
kafkaSinkNoClose :: MonadIO m
                 => KafkaProducer
                 -> Sink ProducerRecord m (Maybe KafkaError)
kafkaSinkNoClose prod = go
  where
    go = do
      mbMsg <- await
      case mbMsg of
        Nothing -> return Nothing
        Just msg -> do
          res <- produceMessage prod msg
          case res of
            Nothing  -> go
            Just err -> return (Just err)

-- | Creates a batching Sink for a given `KafkaProducer`.
-- The producer will NOT be closed automatically.
kafkaBatchSinkNoClose :: MonadIO m
                 => KafkaProducer
                 -> Sink [ProducerRecord] m [(ProducerRecord, KafkaError)]
kafkaBatchSinkNoClose prod = go
  where
    go = do
      mbMsg <- await
      case mbMsg of
        Nothing -> return []
        Just msgs -> do
          res <- produceMessageBatch prod msgs
          case res of
            [] -> go
            xs -> return xs

-- | Creates a kafka producer for given properties and returns a Sink.
--
-- This method of creating a Sink represents a simple case
-- and does not provide access to `KafkaProducer`. For more complex scenarious
-- 'kafkaSinkAutoClose' or 'kafkaSinkNoClose' can be used.
kafkaSink :: MonadResource m
          => ProducerProperties
          -> Sink ProducerRecord m (Maybe KafkaError)
kafkaSink props =
  bracketP mkProducer clProducer runHandler
  where
    mkProducer = newProducer props

    clProducer (Left _)     = return ()
    clProducer (Right prod) = void $ closeProducer prod

    runHandler (Left err) = return (Just err)
    runHandler (Right prod) = do
      mbMsg <- await
      case mbMsg of
        Nothing -> return Nothing
        Just msg -> do
          res <- produceMessage prod msg
          runHandler $ maybe (Right prod) Left res

commitOffsetsSink :: MonadIO m => KafkaConsumer -> Sink i m ()
commitOffsetsSink = awaitForever . const . commitAllOffsets OffsetCommit

flushThenCommitSink :: MonadIO m => KafkaConsumer -> KafkaProducer -> Sink i m ()
flushThenCommitSink c p = awaitForever . const $ do
  flushProducer p
  commitAllOffsets OffsetCommit c
