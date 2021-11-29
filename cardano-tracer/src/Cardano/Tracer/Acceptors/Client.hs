{-# LANGUAGE DataKinds #-}

module Cardano.Tracer.Acceptors.Client
  ( runAcceptorsClient
  ) where

import           Codec.CBOR.Term (Term)
import           Control.Concurrent.Extra (Lock)
import qualified Data.ByteString.Lazy as LBS
import           Data.Void (Void)

import           Cardano.Logging (TraceObject)
import           Ouroboros.Network.Mux (MiniProtocol (..), MiniProtocolLimits (..),
                   MiniProtocolNum (..), MuxMode (..), OuroborosApplication (..),
                   RunMiniProtocol (..), miniProtocolLimits, miniProtocolNum, miniProtocolRun)
import           Ouroboros.Network.Driver.Limits (ProtocolTimeLimits)
import           Ouroboros.Network.IOManager (withIOManager)
import           Ouroboros.Network.Snocket (LocalAddress, LocalSocket, Snocket,
                   localAddressFromPath, localSnocket)
import           Ouroboros.Network.Socket (ConnectionId (..), connectToNode,
                   nullNetworkConnectTracers)
import           Ouroboros.Network.Protocol.Handshake.Codec (cborTermVersionDataCodec,
                   noTimeLimitsHandshake)
import           Ouroboros.Network.Protocol.Handshake.Unversioned (UnversionedProtocol (..),
                   UnversionedProtocolData (..), unversionedHandshakeCodec,
                   unversionedProtocolDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Type (Handshake)
import           Ouroboros.Network.Protocol.Handshake.Version (acceptableVersion,
                   simpleSingletonVersions)
import qualified System.Metrics.Configuration as EKGF
import           System.Metrics.Network.Acceptor (acceptEKGMetricsInit)

import qualified Trace.Forward.Configuration.DataPoint as DPF
import qualified Trace.Forward.Configuration.TraceObject as TF
import           Trace.Forward.Run.DataPoint.Acceptor (acceptDataPointsInit)
import           Trace.Forward.Run.TraceObject.Acceptor (acceptTraceObjectsInit)

import           Cardano.Tracer.Acceptors.Utils (prepareDataPointAsker,
                   prepareMetricsStores, removeDisconnectedNode)
import           Cardano.Tracer.Configuration (TracerConfig)
import           Cardano.Tracer.Handlers.Logs.TraceObjects (traceObjectsHandler)
import           Cardano.Tracer.Types (AcceptedMetrics, ConnectedNodes, DataPointAskers)
import           Cardano.Tracer.Utils (connIdToNodeId)

runAcceptorsClient
  :: TracerConfig
  -> FilePath
  -> ( EKGF.AcceptorConfiguration
     , TF.AcceptorConfiguration TraceObject
     , DPF.AcceptorConfiguration
     )
  -> ConnectedNodes
  -> AcceptedMetrics
  -> DataPointAskers
  -> Lock
  -> IO ()
runAcceptorsClient config p (ekgConfig, tfConfig, dpfConfig)
                   connectedNodes acceptedMetrics dpAskers currentLogLock = withIOManager $ \iocp ->
  doConnectToForwarder (localSnocket iocp) (localAddressFromPath p) noTimeLimitsHandshake $
    -- Please note that we always run all the supported protocols,
    -- there is no mechanism to disable some of them.
    appInitiator
      [ (runEKGAcceptorInit ekgConfig connectedNodes acceptedMetrics errorHandler, 1)
      , (runTraceObjectsAcceptorInit config tfConfig currentLogLock  errorHandler, 2)
      , (runDataPointsAcceptorInit dpfConfig connectedNodes dpAskers errorHandler, 3)
      ]
 where
  appInitiator protocolsWithNums =
    OuroborosApplication $ \connectionId _shouldStopSTM ->
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = protocol connectionId
         }
      | (protocol, num) <- protocolsWithNums
      ]
  errorHandler = removeDisconnectedNode connectedNodes acceptedMetrics dpAskers

doConnectToForwarder
  :: Snocket IO LocalSocket LocalAddress
  -> LocalAddress
  -> ProtocolTimeLimits (Handshake UnversionedProtocol Term)
  -> OuroborosApplication 'InitiatorMode LocalAddress LBS.ByteString IO () Void
  -> IO ()
doConnectToForwarder snocket address timeLimits app =
  connectToNode
    snocket
    unversionedHandshakeCodec
    timeLimits
    (cborTermVersionDataCodec unversionedProtocolDataCodec)
    nullNetworkConnectTracers
    acceptableVersion
    (simpleSingletonVersions
       UnversionedProtocol
       UnversionedProtocolData app
    )
    Nothing
    address

runEKGAcceptorInit
  :: EKGF.AcceptorConfiguration
  -> ConnectedNodes
  -> AcceptedMetrics
  -> (ConnectionId LocalAddress -> IO ())
  -> ConnectionId LocalAddress
  -> RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void
runEKGAcceptorInit ekgConfig connectedNodes acceptedMetrics errorHandler connId =
  acceptEKGMetricsInit
    ekgConfig
    (prepareMetricsStores connectedNodes acceptedMetrics connId)
    (errorHandler connId)

runTraceObjectsAcceptorInit
  :: TracerConfig
  -> TF.AcceptorConfiguration TraceObject
  -> Lock
  -> (ConnectionId LocalAddress -> IO ())
  -> ConnectionId LocalAddress
  -> RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void
runTraceObjectsAcceptorInit config tfConfig currentLogLock errorHandler connId =
  acceptTraceObjectsInit
    tfConfig
    (traceObjectsHandler config (connIdToNodeId connId) currentLogLock)
    (errorHandler connId)

runDataPointsAcceptorInit
  :: DPF.AcceptorConfiguration
  -> ConnectedNodes
  -> DataPointAskers
  -> (ConnectionId LocalAddress -> IO ())
  -> ConnectionId LocalAddress
  -> RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void
runDataPointsAcceptorInit dpfConfig connectedNodes dpAskers errorHandler connId =
  acceptDataPointsInit
    dpfConfig
    (prepareDataPointAsker connectedNodes dpAskers connId)
    (errorHandler connId)