{-# LANGUAGE BangPatterns #-}

-- | Utility functions for TCP sockets
module Network.Transport.TCP.Internal
  ( ControlHeader(..)
  , encodeControlHeader
  , decodeControlHeader
  , ConnectionRequestResponse(..)
  , encodeConnectionRequestResponse
  , decodeConnectionRequestResponse
  , forkServer
  , recvWithLength
  , recvWithLengthFold
  , recvExact
  , recvWord32
  , encodeWord32
  , tryCloseSocket
  , tryShutdownSocketBoth
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Network.Transport.Internal
  ( decodeWord32
  , encodeWord32
  , void
  , tryIO
  , forkIOWithUnmask
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket as N
#else
import qualified Network.Socket as N
#endif
  ( HostName
  , ServiceName
  , Socket
  , SocketType(Stream)
  , SocketOption(ReuseAddr)
  , getAddrInfo
  , defaultHints
  , socket
  , bindSocket
  , listen
  , addrFamily
  , addrAddress
  , defaultProtocol
  , setSocketOption
  , accept
  , sClose
  , socketPort
  , shutdown
  , ShutdownCmd(ShutdownBoth)
  , SockAddr
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket.ByteString as NBS (recv)
#else
import qualified Network.Socket.ByteString as NBS (recv)
#endif

import Data.Word (Word32)

import Control.Monad (forever, when, unless)
import Control.Exception (SomeException, catch, bracketOnError, throwIO, mask_)
import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  )
import Control.Monad (forever, when)
import Control.Exception
  ( SomeException
  , catch
  , bracketOnError
  , throwIO
  , mask_
  , mask
  , finally)

import Control.Applicative ((<$>), (<*>))
import Data.Word (Word32)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.ByteString.Lazy.Internal (smallChunkSize)

-- | Control headers
data ControlHeader =
    -- | Tell the remote endpoint that we created a new connection
    CreatedNewConnection
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection
    -- | Request to close the connection (see module description)
  | CloseSocket
    -- | Sent by an endpoint when it is closed.
  | CloseEndPoint
    -- | Message sent to probe a socket
  | ProbeSocket
    -- | Acknowledgement of the ProbeSocket message
  | ProbeSocketAck
  deriving (Show)

decodeControlHeader :: Word32 -> Maybe ControlHeader
decodeControlHeader w32 = case w32 of
  0 -> Just CreatedNewConnection
  1 -> Just CloseConnection
  2 -> Just CloseSocket
  3 -> Just CloseEndPoint
  4 -> Just ProbeSocket
  5 -> Just ProbeSocketAck
  _ -> Nothing

encodeControlHeader :: ControlHeader -> Word32
encodeControlHeader ch = case ch of
  CreatedNewConnection -> 0
  CloseConnection      -> 1
  CloseSocket          -> 2
  CloseEndPoint        -> 3
  ProbeSocket          -> 4
  ProbeSocketAck       -> 5

-- | Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    -- | /B/ accepts the connection
    ConnectionRequestAccepted
    -- | /A/ requested an invalid endpoint
  | ConnectionRequestInvalid
    -- | /A/s request crossed with a request from /B/ (see protocols)
  | ConnectionRequestCrossed
  deriving (Show)

decodeConnectionRequestResponse :: Word32 -> Maybe ConnectionRequestResponse
decodeConnectionRequestResponse w32 = case w32 of
  0 -> Just ConnectionRequestAccepted
  1 -> Just ConnectionRequestInvalid
  2 -> Just ConnectionRequestCrossed
  _ -> Nothing

encodeConnectionRequestResponse :: ConnectionRequestResponse -> Word32
encodeConnectionRequestResponse crr = case crr of
  ConnectionRequestAccepted -> 0
  ConnectionRequestInvalid  -> 1
  ConnectionRequestCrossed  -> 2

-- | Start a server at the specified address.
--
-- This sets up a server socket for the specified host and port. Exceptions
-- thrown during setup are not caught.
--
-- Once the socket is created we spawn a new thread which repeatedly accepts
-- incoming connections and executes the given request handler in another
-- thread. If any exception occurs the accepting thread terminates and calls
-- the terminationHandler. Threads spawned for previous accepted connections
-- are not killed.
-- This exception may occur because of a call to 'N.accept', or because the
-- thread was explicitly killed.
--
-- If Right is given for the request handler, then it's not responsible for
-- closing the socket. It will be closed once that handler returns. Take care
-- to ensure that the socket is not used after the handler returns, or you will
-- get undefined behavior (the file descriptor may be re-used).
--
-- Use Left if you want to take care of closing it.
--
-- The return value includes the port was bound to. This is not always the same
-- port as that given in the argument. For example, binding to port 0 actually
-- binds to a random port, selected by the OS.
forkServer :: N.HostName                     -- ^ Host
           -> N.ServiceName                  -- ^ Port
           -> Int                            -- ^ Backlog (maximum number of queued connections)
           -> Bool                           -- ^ Set ReuseAddr option?
           -> (SomeException -> IO ())       -- ^ Termination handler
           -> Either (N.Socket -> IO ()) (IO () -> N.Socket -> IO ())
              -- ^ Request handler. If you give Left, we won't close the
              --   socket for you.
           -> IO (N.ServiceName, ThreadId)
forkServer host port backlog reuseAddr terminationHandler requestHandler = do
    -- Resolve the specified address. By specification, getAddrInfo will never
    -- return an empty list (but will throw an exception instead) and will return
    -- the "best" address first, whatever that means
    addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
    bracketOnError (N.socket (N.addrFamily addr) N.Stream N.defaultProtocol)
                   tryCloseSocket $ \sock -> do
      when reuseAddr $ N.setSocketOption sock N.ReuseAddr 1
      N.bindSocket sock (N.addrAddress addr)
      N.listen sock backlog

      -- Close up and fill the synchonizing MVar.
      let release :: ((N.Socket, N.SockAddr), MVar ()) -> IO ()
          release ((sock, _), socketClosed) =
            N.sClose sock `finally` putMVar socketClosed ()

      -- Accept connections and handle them in separate threads, taking care
      -- to close the socket when its handler is finished.
      let acceptRequest :: IO ()
          acceptRequest = do
            (sock, sockAddr) <- N.accept sock
            case requestHandler of
              Left handleNoClose -> void $ mask $ \restore -> forkIO $ do
                restore (handleNoClose sock)
              Right handleClose -> do
                socketClosed <- newEmptyMVar
                void $ mask $ \restore -> forkIO $ do
                  restore (handleClose (readMVar socketClosed) sock)
                  `finally`
                  release ((sock, sockAddr), socketClosed)

      -- We start listening for incoming requests in a separate thread. When
      -- that thread is killed, we close the server socket and the termination
      -- handler is run. We have to make sure that the exception handler is
      -- installed /before/ any asynchronous exception occurs. So we mask_, then
      -- fork (the child thread inherits the masked state from the parent), then
      -- unmask only inside the catch.
      (,) <$> fmap show (N.socketPort sock) <*>
        (mask_ $ forkIOWithUnmask $ \unmask ->
          catch (unmask (forever acceptRequest)) $ \ex -> do
            tryCloseSocket sock
            terminationHandler ex)

-- | Read a length, then 1 or more payloads each less than some maximum
-- length in bytes, such that the sum of their lengths is the length that was
-- read.
recvWithLengthFold
  :: Word32                      -- ^ Maximum total size.
  -> Word32                      -- ^ Maximum chunk size.
  -> N.Socket
  -> t                           -- ^ Start element for the fold.
  -> ([ByteString] -> t -> IO t) -- ^ Run this every time we get data of at
                                 -- most the maximum size.
  -> IO t
recvWithLengthFold maxSize maxChunk sock base folder = do
  len <- recvWord32 sock
  when (len > maxSize) $
    throwIO (userError "recvWithLengthFold: limit exceeded")
  loop base len
  where
  loop !base !total = do
    (bs, received) <- recvExact sock (min maxChunk total)
    base' <- folder bs base
    let remaining = total - received
    when (received > total) $ throwIO (userError "recvWithLengthFold: got more bytes than requested")
    if remaining == 0
    then return base'
    else loop base' remaining

-- | Read a length and then a payload of that length
recvWithLength
  :: Word32          -- ^ Maximum total size.
  -> N.Socket
  -> IO [ByteString]
recvWithLength maxSize sock = fmap (concat . reverse) $
  recvWithLengthFold maxSize maxBound sock [] $
    \bs lst -> return (bs : lst)

-- | Receive a 32-bit unsigned integer
recvWord32 :: N.Socket -> IO Word32
recvWord32 = fmap (decodeWord32 . BS.concat . fst) . flip recvExact 4

-- | Close a socket, ignoring I/O exceptions.
tryCloseSocket :: N.Socket -> IO ()
tryCloseSocket sock = void . tryIO $
  N.sClose sock

-- | Shutdown socket sends and receives, ignoring I/O exceptions.
tryShutdownSocketBoth :: N.Socket -> IO ()
tryShutdownSocketBoth sock = void . tryIO $
  N.shutdown sock N.ShutdownBoth

-- | Read an exact number of bytes from a socket
--
-- Throws an I/O exception if the socket closes before the specified
-- number of bytes could be read
recvExact :: N.Socket                  -- ^ Socket to read from
          -> Word32                    -- ^ Number of bytes to read
          -> IO ([ByteString], Word32) -- ^ Data and number of bytes read
recvExact _ len | len < 0 = throwIO (userError "recvExact: Negative length")
recvExact sock len = go [] 0 len
  where
    go :: [ByteString] -> Word32 -> Word32 -> IO ([ByteString], Word32)
    go acc !n 0 = return (reverse acc, n)
    go acc !n l = do
      bs <- NBS.recv sock (fromIntegral l `min` smallChunkSize)
      if BS.null bs
        then throwIO (userError "recvExact: Socket closed")
        else do
          let received  = fromIntegral (BS.length bs)
              remaining = l - received
              total     = n + received
          -- Check for underflow. Shouldn't be possible but let's make sure.
          when (received > l) $ throwIO (userError "recvExact: got more bytes than requested")
          go (bs : acc) total remaining
