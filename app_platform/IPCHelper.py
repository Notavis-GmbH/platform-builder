import asyncio
import logging
import traceback
import zmq
import zmq.asyncio
import msgpack
import numpy as np
from operator import itemgetter
from enum import IntEnum
import cv2
import json
import inspect
import queue
import threading
import os
import logging
import numpy as np
import time
from typing import Callable, Dict, Union
from Helpers.ImageHelper import ImageHelper
from shared.BasicTypes import ParameterType
NoneResponse =  Callable[[dict],None]
Response =  Callable[[dict],bytes]
SocketCallback = Union[NoneResponse,Response]

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

class CommandType(IntEnum):

    EXIT = 0
    START_ACQUISITION = 1
    STOP_ACQUISITION = 2
    CONNECT = 3
    SOFTWARE_TRIGGER = 4
    CAMERA_COMMAND = 5


class SocketInterface:
    cancelToken: bool = False
    event = asyncio.Event()
    sending : bool = False
    lock = asyncio.Lock()
    id : int = -1
    helper = ImageHelper()
    sendQueue: queue.PriorityQueue = None
    
    def connect(self, showInfo = True) -> None:
        global logger
        self.socket = self.context.socket(self.socket_type)
        # self.cancelToken = False
        self.stop = False

        if (self.bind):
            if(showInfo): logger.info("Binding to " + self.IPCConnection_Control)
            ipcMode = self.IPCConnection_Control.startswith("ipc://")
            full_path = os.path.dirname(os.path.abspath(self.IPCConnection_Control[6:]))
            if(ipcMode and not os.path.exists(full_path)): 
                    logging.info("Creating directory " + full_path)
                    os.makedirs(full_path)
                    os.chmod(full_path, 0o0777)
            self.socket.bind(self.IPCConnection_Control)
            
            if(ipcMode):
                filename = self.IPCConnection_Control[6:]  
                full_path = os.path.dirname(os.path.abspath(filename))
         
                
                os.chmod(filename, 0o0777)
            

            

        else:
            if(showInfo): logger.info("Connecting to " + self.IPCConnection_Control)
            self.socket.connect(self.IPCConnection_Control)
        self.send_answer = self.canSend()
        
        self.socket.setsockopt(zmq.RCVTIMEO, 20000)
        self.socket.setsockopt(zmq.SNDTIMEO, 5000)
        if(self.socket_type == zmq.SocketType.REQ):
            self.socket.setsockopt(zmq.REQ_RELAXED, 1)
    
    async def worker(self):
        while (not self.cancelToken):
            item = self.sendQueue.get()
            try:
                await self.socket.send(item[1])

                if self.send_answer:
                    # logger.info("Waiting for answer")
                    reply = await self.socket.recv()

                    # return reply
            except asyncio.CancelledError:
                # if (sent):
                #     await self.socket.recv()
                logger.error('Canceled sending')
                self.sendQueue.task_done()

                raise
            except zmq.error.ZMQError as excp:
                if(excp.errno != 11):
                    logger.error(self.IPCConnection_Control)
                    logger.error(excp.errno)
                    logger.error(excp)
                self.connect(False)

            self.sendQueue.task_done()
            if(len(item)==3 and item[2] is not None):
                item[2].set()




    def __init__(self, IPCControl: str, bind: bool = False,
                 type: zmq.SocketType = zmq.SocketType.SUB,
                 id: int = -1, queueSending: bool = False) -> None:
        logger = logging.getLogger("Zeromq")
        logger.setLevel(logging.INFO)
        
        self.context = zmq.asyncio.Context()
        self.bind = bind
        self.IPCConnection_Control = IPCControl
        self.socket_type = type
        self.id = id
        
        if queueSending:
            self.sendQueue = queue.PriorityQueue()
            self.workerThread = threading.Thread(target=asyncio.run, args=(self.worker(),))
            self.workerThread.start()



        self.connect()


    def enqueue_message(self, message: bytes, prio: int = 1, event: asyncio.Event = None):
        self.sendQueue.put((prio, message, event))
        
           

    def __del__(self) -> None:
        pass
    
    

    def canSend(self) -> bool:
        
        if self.socket_type == zmq.SocketType.PAIR:
            return True
        elif self.socket_type == zmq.SocketType.REP:
            return True
        elif self.socket_type == zmq.SocketType.REQ:
            return True
        else:
            return False
        # match self.socket_type:
        #     case zmq.SocketType.PAIR:
        #         return True
        #     case zmq.SocketType.REP:
        #         return True
        #     case zmq.SocketType.REQ:
        #         return True
        #     case _:
        #         return False

    async def sendV4Command(self, command_name: str, meta: dict = None, retry: bool = True, msgPack: bool = True) -> bool | dict:
        logger.info("COMMAND")

        command = {"command": command_name, "type": int(ParameterType.COMMAND)}
        if meta is not None:
            command.update(meta)
        logger.info(command)

        sent = False
        MAX_RETRIES = 5
        retry = 0
        if(msgPack):
            msgCommand = msgpack.dumps(command)
        else:
            msgCommand = json.dumps(command)

        # async with self.lock:
        while (not sent and retry < MAX_RETRIES):
            retry += 1            
            try:
                if(msgPack):                    
                    await self.socket.send(msgCommand)
                else:
                    await self.socket.send(b'', flags=zmq.SNDMORE)
                    await self.socket.send_string(msgCommand)
                if self.send_answer:
                    # logger.info("Waiting for answer")
                    if(msgPack): 
                        answer = await self.socket.recv()
                    else:
                        answer = await self.socket.recv()

                        # answer = await self.socket.recv_multipart()
                        # print(answer)
                        # answer = json.loads(answer[1])
                    logger.info(f"Answer: {answer}")
                    return msgpack.unpackb(answer, raw=False)
                    
                sent = True
            except zmq.error.ZMQError as excp:
                if(excp.errno != 11):
                    logger.error(self.IPCConnection_Control)
                    logger.error(excp)
                    logger.error(excp.errno)
                    if(not self.bind):
                        self.connect(True)
                    if(retry == 1):
                        continue
           
            if (not retry):
                break
        return sent

    async def sendCommand(self, command: CommandType, name: str = ""):
        jCommand = {"type": 5, "command": int(command), "name": name}
        await self.socket.send_json(jCommand)

    async def send(self, message: bytes) -> Union[bytes,None]:
        async with self.lock:
            try:

                await self.socket.send(message)
                logger.info("Sent message")
                if self.send_answer:
                    reply  = await self.socket.recv()
                    logger.info("Received message")

                    return reply
                return None
            except zmq.error.ZMQError as excp:
                logger.error(self.IPCConnection_Control)
                logger.error(excp)
                return None
                
                
    async def sendString(self, message: str):
        await self.send(message.encode())
        
        
    
    def castMessage(self,image: cv2.Mat, meta: dict = None, ismsgPack= True) -> bytes:
        msg = {"dataformat": {"type": "raw",
                                "rows": image.shape[0], 
                              "cols": image.shape[1],
                              "channels": 1 if len(
            image.shape) == 2 else image.shape[2]}}
        if(meta is not None):
            msg.update({"meta":meta})
        if(ismsgPack):
            # msg["data"] = image.tobytes()
            return msgpack.dumps(msg)
        else:
            return json.dumps(msg)
    
    def castMessageEncoded(self,image: bytes, shape: list= (1,1,1), type: str = "jpg", meta:dict = None):
        msg = {"dataformat": {"type": type, "cols": shape[0], "rows": shape[1], "channels": shape[2]}, "data": image}
        if(meta is not None):
            msg.update({"meta":meta})
        return msgpack.dumps(msg)

    async def sendImage(self, image: cv2.Mat, meta: dict = None, event: asyncio.Event = None, msgpack= True) -> Union[bytes,None]:       
        
        async with self.lock:

            sent: bool = False           
            
            msg = self.castMessage(image, meta, msgpack)

            if(self.sendQueue is not None):            
                self.enqueue_message(msg)
            else:
                try:
                    if(msgpack):
                        await self.socket.send(image.tobytes(), flags=zmq.SNDMORE)
                        await self.socket.send(msg, flags=zmq.NOBLOCK)
                    else:
                        await self.socket.send(image.tobytes(), flags=zmq.SNDMORE)
                        await self.socket.send_string(msg, flags=zmq.NOBLOCK)
                    if self.send_answer:
                        # logger.info("Waiting for answer")
                        reply = await self.socket.recv_multipart()
                        if (len(reply) == 1):
                            reply = reply[0]
                        return reply
                except zmq.error.ZMQError as excp:
                    if(excp.errno != 11):
                        logger.error(self.IPCConnection_Control)
                        logger.error(excp.errno)
                        logger.error(excp)
                    self.connect(False)

        
    async def sendImageEncoded(self, image: bytes,shape: list= (1,1,1), meta: dict = None):       

        async with self.lock:         
            
            msg = self.castMessageEncoded(image,shape,"jpg",  meta)           
            
            self.enqueue_message(msg,0)
     

     


    def dispatchImage(self, image):
        self.q.put(image)

    def castImage(self, message: dict) -> cv2.Mat:
        data = message['data']
        match message['dataformat']['type']:
            case 'jpg':
                input = np.frombuffer(bytes(data), np.uint8)                           

                img = cv2.imdecode(input,cv2.IMREAD_ANYCOLOR)
                print(img.shape)
            case 'raw':
                rows, cols, channels = itemgetter('rows', 'cols', 'channels')(message["dataformat"])

                img = np.frombuffer(data, dtype=np.uint8)
                img = np.reshape(img, (rows, cols, channels))
            case 'both':
                rows, cols, channels = itemgetter('rows', 'cols', 'channels')(message["dataformat"])

                img = np.frombuffer(data, dtype=np.uint8)
                img = np.reshape(img, (rows, cols, channels))
            case _:
                print("no")
        return img
    def castImageMultiMessage(self, message: tuple[dict,np.ndarray]) -> cv2.Mat:
        data = message[1]
        message = message[0]
        match message['dataformat']['type']:
            case 'jpg':
                input = np.frombuffer(bytes(data), np.uint8)                           

                img = cv2.imdecode(input,cv2.IMREAD_ANYCOLOR)
                print(img.shape)
            case 'raw':
                rows, cols, channels = itemgetter('rows', 'cols', 'channels')(message["dataformat"])

                img = np.frombuffer(data, dtype=np.uint8)
                img = np.reshape(img, (rows, cols, channels))
            case 'both':
                rows, cols, channels = itemgetter('rows', 'cols', 'channels')(message["dataformat"])

                img = np.frombuffer(data, dtype=np.uint8)
                img = np.reshape(img, (rows, cols, channels))
            case _:
                print("no")
        return img

    async def zmqloop(self, callbacks: Dict[str,SocketCallback] = {}, isMsgpack: bool = True):
        global logger
        logger.info("Starting loop for " + self.IPCConnection_Control)

        while not self.cancelToken:
            await asyncio.sleep(0.001)
            # logger.info(f"Next round {self.IPCConnection_Control}")

            try:
                messages = await self.socket.recv_multipart()  # will wait for the next message

                logger.debug("Received message")

                try:
                    startLoad = time.time()
                    if(isMsgpack):                      
                        if isinstance(messages, list) and len(messages) > 0:
                            logger.info("Received message as multipart")
                            
                            try:
                                image_pack = msgpack.unpackb(
                                    messages[0], 
                                    strict_map_key=False,
                                    raw=False,
                                    use_list=True
                                )
                            except TypeError as te:
                                # If we get unhashable type error, the message has malformed data
                                # (dict used as a key). This is a sender issue, skip this message.
                                if "unhashable type" in str(te):
                                    logger.warning(f"Skipping message with malformed msgpack data (unhashable key): {te}")
                                    logger.warning(f"Message size: {len(messages[0])} bytes")
                                    # Write the binary data to a log file for analysis
                                    with open("unhashable_msgpack.bin", "wb") as f:
                                        f.write(messages[0])
                                    logger.warning("Binary data written to unhashable_msgpack.bin for analysis")
                                    continue

                            except (ValueError, msgpack.exceptions.OutOfData) as e:
                                logger.error(f"Msgpack unpacking error: {e}")
                                logger.error(f"Message type: {type(messages[0])}")
                                logger.error(f"Messages list length: {len(messages)}")
                                # Write message raw to file for analysis
                                try:
                                    if isinstance(messages[0], (bytes, bytearray)):
                                        logger.error(f"Message length: {len(messages[0])} bytes")
                                        with open("msgpack_error_raw.bin", "wb") as f:
                                            f.write(messages[0])
                                        logger.error("Raw message written to msgpack_error_raw.bin for analysis")
                                        # For incomplete input, just skip this message
                                        if isinstance(e, msgpack.exceptions.OutOfData):
                                            logger.warning("Incomplete msgpack message received, skipping")
                                            continue
                                    else:
                                        logger.error("Message content: " + str(messages[0]))
                                except Exception as file_exc:
                                    logger.error(f"Failed to write raw message to file: {file_exc}")
                                    continue
                                # raise
                        else:
                            logger.error(f"Unexpected message type: {type(messages)}")
                            # raise ValueError(f"Unexpected message type: {type(messages)}")
                            
                        if isinstance(messages, list) and len(messages) > 1:
                            image_pack["data"] = messages[1]
                        if isinstance(messages, list) and len(messages) > 2:                        
                            image_pack["base64"] = messages[2]
                        
                    else:
                        image_pack = json.loads(messages[0])
                        if isinstance(messages, list) and len(messages) > 1:
                            image_pack["data"] = str(messages[1])
                        if isinstance(messages, list) and len(messages) > 2:                        
                            image_pack["base64"] = str(messages[2])
                    # if (not "data" in image_pack):             
                    #     logger.info(f"Found key {image_pack}")

                    keyFound = False
                    detectedKey = ""
                    result = None

                    for key, fn in callbacks.items():
                        if (key in image_pack):
                            logger.debug(f"Found key {key}")
                            if (inspect.iscoroutinefunction(fn)):
                                if(self.id >= 0):
                                    result = await fn(image_pack, self.id)
                                else:
                                    result = await fn(image_pack)
                            else:
                                if(self.id >= 0):
                                    result = fn(image_pack, self.id)
                                else:
                                    result = fn(image_pack)
                            keyFound = True
                            detectedKey = key

                    if (not keyFound):
                        logger.info(image_pack.keys())
                    elif ("data" not in image_pack):
                        logger.debug(f"FOUND: {json.dumps(image_pack, indent=4)}")
                    else:
                        logger.debug(f"Found key {detectedKey}")
                    del image_pack
                    if (self.send_answer):
                        if(result is not None):
                            await self.socket.send(result)
                        else:
                            await self.socket.send(msgpack.dumps("OK"))
                        # logger.info("Sent answer")
                except Exception as e:
                    # logger.error(messages)
                    logger.error(e)
                    logger.error("Failed to process message")
                    # Write the binary data to a log file for analysis
                    try:
                        if isinstance(messages, list) and len(messages) > 0 and isinstance(messages[0], (bytes, bytearray)):
                            with open("/dump/failed_message.bin", "wb") as f:
                                f.write(messages[0])
                            logger.error("Binary data written to failed_message.bin for analysis")
                    except Exception as write_exc:
                        logger.error(f"Failed to write binary data: {write_exc}")
                    traceback.print_exc()
                    if (self.send_answer):
                        self.socket.send_string(f"failed to process request: {str(e)}")

            except zmq.error.Again as excp:
                #pass
                if(excp.errno != 11):
                    logger.error(self.IPCConnection_Control)
                    logger.error(excp.errno)
                    logger.error(excp)
                    self.connect(False)
             

            except Exception as e:
                # to make sure that response was sent
                if (self.send_answer):
                    self.socket.send_string(f"failed to process request: {str(e)}")
                traceback.print_exc()
                logger.error(e)
                logger.error(len(messages))
