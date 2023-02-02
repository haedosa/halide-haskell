-- |
-- Copyright: (c) 2021 Tom Westerhout
-- SPDX-License-Identifier: BSD-3-Clause
-- Maintainer: Tom Westerhout <14264576+twesterhout@users.noreply.github.com>
--
-- See README for more info
module Language.Halide.Buffer
  ( HalideBuffer (..),
    RawHalideBuffer (..),
    bufferFromPtrShape,
    bufferFromPtrShapeStrides,
    HalideDimension (..),
    IsHalideBuffer (..),
  )
where

import Control.Monad (unless)
import Control.Monad.ST (RealWorld)
import Data.Bits
import Data.Coerce
import Data.Int
import Data.Kind (Type)
import Data.Proxy
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import Data.Word
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable
import GHC.Stack (HasCallStack)
import GHC.TypeNats
import Language.Halide.Type

data HalideDimension = HalideDimension
  { halideDimensionMin :: {-# UNPACK #-} !Int32,
    halideDimensionExtent :: {-# UNPACK #-} !Int32,
    halideDimensionStride :: {-# UNPACK #-} !Int32,
    halideDimensionFlags :: {-# UNPACK #-} !Word32
  }
  deriving stock (Read, Show, Eq)

instance Storable HalideDimension where
  sizeOf _ = 16
  {-# INLINE sizeOf #-}
  alignment _ = 4
  {-# INLINE alignment #-}
  peek p =
    HalideDimension
      <$> peekByteOff p 0
      <*> peekByteOff p 4
      <*> peekByteOff p 8
      <*> peekByteOff p 12
  {-# INLINE peek #-}
  poke p x = do
    pokeByteOff p 0 (halideDimensionMin x)
    pokeByteOff p 4 (halideDimensionExtent x)
    pokeByteOff p 8 (halideDimensionStride x)
    pokeByteOff p 12 (halideDimensionFlags x)
  {-# INLINE poke #-}

toInt32 :: (HasCallStack, Bits a, Integral a) => a -> Int32
toInt32 x = case toIntegralSized x of
  Just y -> y
  Nothing -> error $ "integer overflow when converting " <> show (toInteger x) <> " to Int32"
{-# INLINE toInt32 #-}

-- | @simpleDimension extent stride@ creates a @HalideDimension@ of size @extent@ separated by
-- @stride@.
simpleDimension :: Int -> Int -> HalideDimension
simpleDimension extent stride = HalideDimension 0 (toInt32 extent) (toInt32 stride) 0
{-# INLINE simpleDimension #-}

rowMajorStrides :: Integral a => [a] -> [a]
rowMajorStrides = drop 1 . scanr (*) 1

data HalideDeviceInterface

data RawHalideBuffer = RawHalideBuffer
  { halideBufferDevice :: !Word64,
    halideBufferDeviceInterface :: !(Ptr HalideDeviceInterface),
    halideBufferHost :: !(Ptr Word8),
    halideBufferFlags :: !Word64,
    halideBufferType :: !HalideType,
    halideBufferDimensions :: !Int32,
    halideBufferDim :: !(Ptr HalideDimension),
    halideBufferPadding :: !(Ptr ())
  }
  deriving stock (Show, Eq)

newtype HalideBuffer (n :: Nat) (a :: Type) = HalideBuffer {unHalideBuffer :: RawHalideBuffer}
  deriving stock (Show, Eq)

instance Storable RawHalideBuffer where
  sizeOf _ = 56
  alignment _ = 8
  peek p =
    RawHalideBuffer
      <$> peekByteOff p 0 -- device
      <*> peekByteOff p 8 -- interface
      <*> peekByteOff p 16 -- host
      <*> peekByteOff p 24 -- flags
      <*> peekByteOff p 32 -- type
      <*> peekByteOff p 36 -- dimensions
      <*> peekByteOff p 40 -- dim
      <*> peekByteOff p 48 -- padding
  poke p x = do
    pokeByteOff p 0 (halideBufferDevice x)
    pokeByteOff p 8 (halideBufferDeviceInterface x)
    pokeByteOff p 16 (halideBufferHost x)
    pokeByteOff p 24 (halideBufferFlags x)
    pokeByteOff p 32 (halideBufferType x)
    pokeByteOff p 36 (halideBufferDimensions x)
    pokeByteOff p 40 (halideBufferDim x)
    pokeByteOff p 48 (halideBufferPadding x)

bufferFromPtrShapeStrides ::
  forall n a b.
  (KnownNat n, IsHalideType a, Coercible (HalideBuffer n a) RawHalideBuffer) =>
  Ptr a ->
  [Int] ->
  [Int] ->
  (Ptr (HalideBuffer n a) -> IO b) ->
  IO b
bufferFromPtrShapeStrides p shape stride action =
  withArrayLen (zipWith simpleDimension shape stride) $ \n dim -> do
    unless (n == fromIntegral (natVal (Proxy @n))) $
      error $
        "specified wrong number of dimensions: "
          <> show n
          <> "; expected "
          <> show (natVal (Proxy @n))
          <> " from the type declaration"
    let !buffer =
          RawHalideBuffer
            { halideBufferDevice = 0,
              halideBufferDeviceInterface = nullPtr,
              halideBufferHost = castPtr p,
              halideBufferFlags = 0,
              halideBufferType = halideTypeFor (Proxy :: Proxy a),
              halideBufferDimensions = toInt32 n,
              halideBufferDim = dim,
              halideBufferPadding = nullPtr
            }
    with buffer (action . castPtr)

bufferFromPtrShape ::
  forall n a b.
  (KnownNat n, IsHalideType a) =>
  Ptr a ->
  [Int] ->
  (Ptr (HalideBuffer n a) -> IO b) ->
  IO b
bufferFromPtrShape p shape = bufferFromPtrShapeStrides p shape (rowMajorStrides shape)

class (KnownNat n, IsHalideType a) => IsHalideBuffer t n a | t -> n, t -> a where
  withHalideBuffer :: t -> (Ptr (HalideBuffer n a) -> IO b) -> IO b

-- withRawHalideBuffer :: forall n a t b. IsHalideBuffer t n a => t -> (Ptr RawHalideBuffer -> IO b) -> IO b
-- withRawHalideBuffer x f = withHalideBuffer x $ \(HalideBuffer raw) -> with raw f

instance (IsHalideType a, Storable a) => IsHalideBuffer (S.Vector a) 1 a where
  withHalideBuffer v f =
    S.unsafeWith v $ \dataPtr ->
      bufferFromPtrShape dataPtr [S.length v] f

instance (IsHalideType a, Storable a) => IsHalideBuffer (S.MVector RealWorld a) 1 a where
  withHalideBuffer v f =
    SM.unsafeWith v $ \dataPtr ->
      bufferFromPtrShape dataPtr [SM.length v] f