{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE TemplateHaskell     #-}

module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform.Service.Registry
  ( Registry(..)
  , Keyable
  , KeyUpdateEventMask(..)
  , KeyUpdateEvent(..)
  , RegistryKeyMonitorNotification(..)
  , addName
  , registerName
  , unregisterName
  , lookupName
  , registeredNames
  , awaitTimeout
  , AwaitResult(..)
  , RegisterKeyReply(..)
  , UnregisterKeyReply(..)
  )
import qualified Control.Distributed.Process.Platform.Service.Registry as Registry
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Control.Monad (void, forM_)
import Control.Rematch
  ( equalTo
  )

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.HUnit (Assertion)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

import qualified Network.Transport as NT

myRegistry :: Registry String ()
myRegistry = LocalRegistry

withRegistry :: forall k v. (Keyable k, Serializable v)
             => LocalNode
             -> Registry k v
             -> (ProcessId -> Process ())
             -> Assertion
withRegistry node reg proc = do
  runProcess node $ do
    reg' <- Registry.start reg
    (proc reg') `finally` (kill reg' "goodbye")

testAddLocalName :: TestResult RegisterKeyReply -> Process ()
testAddLocalName result = do
  reg <- Registry.start myRegistry
  stash result =<< addName reg "foobar"

testCheckLocalName :: ProcessId -> Process ()
testCheckLocalName reg = do
  void $ addName reg "fwibble"
  fwibble <- lookupName reg "fwibble"
  selfPid <- getSelfPid
  fwibble `shouldBe` equalTo (Just selfPid)

testMultipleRegistrations :: ProcessId -> Process ()
testMultipleRegistrations reg = do
  self <- getSelfPid
  forM_ names (addName reg)
  forM_ names $ \name -> do
    found <- lookupName reg name
    found `shouldBe` equalTo (Just self)
  where
    names = ["foo", "bar", "baz"]

testDuplicateRegistrations :: ProcessId -> Process ()
testDuplicateRegistrations reg = do
  void $ addName reg "foobar"
  RegisteredOk <- addName reg "foobar"
  pid <- spawnLocal $ (expect :: Process ()) >>= return
  result <- registerName reg "foobar" pid
  result `shouldBe` equalTo AlreadyRegistered

testUnregisterName :: ProcessId -> Process ()
testUnregisterName reg = do
  self <- getSelfPid
  void $ addName reg "fwibble"
  void $ addName reg "fwobble"
  Just self' <- lookupName reg "fwibble"
  self' `shouldBe` equalTo self
  unreg <- unregisterName reg "fwibble"
  unreg `shouldBe` equalTo UnregisterOk
  fwobble <- lookupName reg "fwobble"
  fwobble `shouldBe` equalTo (Just self)

testUnregisterUnknownName :: ProcessId -> Process ()
testUnregisterUnknownName reg = do
  result <- unregisterName reg "no.such.name"
  result `shouldBe` equalTo UnregisterKeyNotFound

testUnregisterAnothersName :: ProcessId -> Process ()
testUnregisterAnothersName reg = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    void $ addName reg "proc.name"
    sendChan sp ()
    (expect :: Process ()) >>= return
  () <- receiveChan rp
  found <- lookupName reg "proc.name"
  found `shouldBe` equalTo (Just pid)
  unreg <- unregisterName reg "proc.name"
  unreg `shouldBe` equalTo UnregisterInvalidKey

testProcessDeathHandling :: ProcessId -> Process ()
testProcessDeathHandling reg = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    void $ addName reg "proc.name.1"
    void $ addName reg "proc.name.2"
    sendChan sp ()
    (expect :: Process ()) >>= return
  () <- receiveChan rp
  void $ monitor pid
  regNames <- registeredNames reg pid
  regNames `shouldBe` equalTo ["proc.name.1", "proc.name.2"]
  send pid ()
  receiveWait [
      match (\(ProcessMonitorNotification _ _ _) -> return ())
    ]
  forM_ [1..2 :: Int] $ \n -> do
    let name = "proc.name." ++ (show n)
    found <- lookupName reg name
    found `shouldBe` equalTo Nothing
  regNames' <- registeredNames reg pid
  regNames' `shouldBe` equalTo ([] :: [String])

testMonitorName :: ProcessId -> Process ()
testMonitorName reg = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    void $ addName reg "proc.name.1"
    void $ addName reg "proc.name.2"
    sendChan sp ()
    (expect :: Process ()) >>= return
  () <- receiveChan rp
  mRef <- Registry.monitorName reg "proc.name.2"
  send pid ()
  res <- receiveTimeout (after 2 Seconds) [
      matchIf (\(RegistryKeyMonitorNotification k ref _) ->
                k == "proc.name.2" && ref == mRef)
              (\(RegistryKeyMonitorNotification _ _ ev) -> return ev)
    ]
  res `shouldBe` equalTo (Just (KeyOwnerDied DiedNormal))

testMonitorUnregistration :: ProcessId -> Process ()
testMonitorUnregistration reg = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    void $ addName reg "proc.1"
    sendChan sp ()
    expect :: Process ()
    void $ unregisterName reg "proc.1"
    sendChan sp ()
    (expect :: Process ()) >>= return
  () <- receiveChan rp
  mRef <- Registry.monitorName reg "proc.1"
  send pid ()
  () <- receiveChan rp
  res <- receiveTimeout (after 2 Seconds) [
      matchIf (\(RegistryKeyMonitorNotification k ref _) ->
                k == "proc.1" && ref == mRef)
              (\(RegistryKeyMonitorNotification _ _ ev) -> return ev)
    ]
  res `shouldBe` equalTo (Just KeyUnregistered)

testMonitorRegistration :: ProcessId -> Process ()
testMonitorRegistration reg = do
  kRef <- Registry.monitorName reg "my.proc"
  pid <- spawnLocal $ do
    void $ addName reg "my.proc"
    expect :: Process ()
  res <- receiveTimeout (after 2 Seconds) [
      matchIf (\(RegistryKeyMonitorNotification k ref _) ->
                k == "my.proc" && ref == kRef)
              (\(RegistryKeyMonitorNotification _ _ ev) -> return ev)
    ]
  res `shouldBe` equalTo (Just (KeyRegistered pid))

testAwaitRegistration :: ProcessId -> Process ()
testAwaitRegistration reg = do
  pid <- spawnLocal $ do
    void $ addName reg "foo.bar"
    expect :: Process ()
  res <- awaitTimeout reg (Delay $ within 5 Seconds) "foo.bar"
  res `shouldBe` equalTo (RegisteredName pid "foo.bar")

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
  let testProc = withRegistry localNode
  return [
        testGroup "Name Registration/Unregistration"
        [
          testCase "Simple Registration"
           (delayedAssertion
            "expected the server to return the incremented state as 7"
            localNode RegisteredOk testAddLocalName)
        , testCase "Verified Registration"
           (testProc myRegistry testCheckLocalName)
        , testCase "Single Process, Multiple Registered Names"
           (testProc myRegistry testMultipleRegistrations)
        , testCase "Duplicate Registration Fails"
           (testProc myRegistry testDuplicateRegistrations)
        , testCase "Unregister Own Name"
           (testProc myRegistry testUnregisterName)
        , testCase "Unregister Unknown Name"
           (testProc myRegistry testUnregisterUnknownName)
        , testCase "Unregister Someone Else's Name"
           (testProc myRegistry testUnregisterAnothersName)
        ]
      , testGroup "Named Process Monitoring/Tracking"
        [
          testCase "Process Death Results In Unregistration"
           (testProc myRegistry testProcessDeathHandling)
        , testCase "Monitoring Name Changes"
           (testProc myRegistry testMonitorName)
        , testCase "Monitoring Registration"
           (testProc myRegistry testMonitorRegistration)
        , testCase "Awaiting Registration"
           (testProc myRegistry testAwaitRegistration)
        , testCase "Monitoring Unregistration"
           (testProc myRegistry testMonitorUnregistration)
        ]
    ]

main :: IO ()
main = testMain $ tests
