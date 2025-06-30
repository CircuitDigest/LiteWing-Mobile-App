package se.bitcraze.crazyfliecontrol2;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.util.Log;

import androidx.lifecycle.Observer;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.Arrays;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import se.bitcraze.crazyflie.lib.crtp.CrtpDriver;
import se.bitcraze.crazyflie.lib.crtp.CrtpPacket;

public class EspUdpDriver extends CrtpDriver {
    private static final String TAG = "EspUdpDriver";

    private static final int APP_PORT = 2399;
    private static final int DEVICE_PORT = 2390;
    private static final String DEVICE_ADDRESS = "192.168.43.42";

    private volatile boolean mConnectMark = false;
    private volatile DatagramSocket mSocket;
    private volatile ReceiveThread mReceiveThread;
    private volatile PostThread mPostThread;

    private final EspActivity mActivity;
    private final BlockingQueue<CrtpPacket> mInQueue;
    private final WifiManager mWifiManager;

    private Observer<String> mObserver = new Observer<String>(){
        @Override
        public void onChanged(String s) {
            int networkId = mWifiManager.getConnectionInfo().getNetworkId();
            if (networkId == -1) {
                disconnect();
                notifyConnectionLost("No SoftAP connection");
            } else {
                if (mConnectMark) {
                    mConnectMark = false;
                    try {
                        InetAddress deviceAddress = InetAddress.getByName(DEVICE_ADDRESS);
                        mSocket = new DatagramSocket(null);
                        mSocket.setReuseAddress(true);
                        mSocket.bind(new InetSocketAddress(APP_PORT));
                        mReceiveThread = new ReceiveThread(mSocket);
                        mReceiveThread.setPacketQueue(mInQueue);
                        mReceiveThread.start();
                        mPostThread = new PostThread(mSocket, deviceAddress);
                        mPostThread.start();
                        notifyConnected();
                    } catch (IOException e) {
                        if (mSocket != null) {
                            mSocket.close();
                            mSocket = null;
                        }
                        mActivity.removeBroadcastObserver(mObserver);
                        notifyConnectionFailed("Create socket failed");
                    }
                }
            }
        }
    };

    public EspUdpDriver(EspActivity activity) {
        mActivity = activity;
        mWifiManager = (WifiManager) activity.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        mInQueue = new LinkedBlockingQueue<>();
    }

    @Override
    public void connect() throws IOException {
        Log.w(TAG, "Connect()");
        if (mSocket != null) {
            throw new IllegalStateException("Connection already started");
        }

        mConnectMark = true;
        notifyConnectionRequested();
        mActivity.observeBroadcast(mActivity, mObserver);
    }

    @Override
    public void disconnect() {
        mActivity.removeBroadcastObserver(mObserver);
        if (mSocket != null) {
            mSocket.close();
            mSocket = null;
            mReceiveThread.interrupt();
            mReceiveThread.setPacketQueue(null);
            mReceiveThread = null;
            mPostThread.interrupt();
            mPostThread = null;
            notifyDisconnected();
        }
    }

    @Override
    public boolean isConnected() {
        return mSocket != null && !mSocket.isClosed();
    }

    @Override
    public void sendPacket(CrtpPacket packet) {
        if (mSocket == null || mPostThread == null) {
            return;
        }

        mPostThread.sendPacket(packet);
    }

    @Override
    public CrtpPacket receivePacket(int wait) {
        try {
            return mInQueue.poll(wait, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Log.w(TAG, "ReceivePacket Interrupted");
            return null;
        }
    }

    private static class PostThread extends Thread {
        private BlockingQueue<CrtpPacket> mmQueue = new LinkedBlockingQueue<>();
        private DatagramSocket mmSocket;
        private InetAddress mmDevAddress;

        PostThread(DatagramSocket socket, InetAddress devAddress) {
            mmSocket = socket;
            mmDevAddress = devAddress;
        }

        void sendPacket(CrtpPacket packet) {
            mmQueue.add(packet);
        }

        @Override
        public void run() {
            while (!mmSocket.isClosed() && !isInterrupted()) {
                try {
                    CrtpPacket packet = mmQueue.take();
                    byte[] data = packet.toByteArray();
                    byte[] buf = new byte[data.length + 1];
                    System.arraycopy(data, 0, buf, 0, data.length);
                    int checksum = 0;
                    for (byte b : data) {
                        checksum += (b & 0xff);
                    }
                    buf[buf.length - 1] = (byte) checksum;
                    Log.w(TAG, "run: PostData: " + Arrays.toString(buf));
                    DatagramPacket udpPacket = new DatagramPacket(buf, buf.length, mmDevAddress, DEVICE_PORT);
                    mmSocket.send(udpPacket);
                } catch (IOException e) {
                    Log.w(TAG, "sendPacket: IOException: " + e.getMessage());
                    mmSocket.close();
                    break;
                } catch (InterruptedException e) {
                    break;
                }
            }

            Log.d(TAG, "run: PostThread End");
        }
    }

    private static class ReceiveThread extends Thread {
        private DatagramSocket mmSocket;
        private BlockingQueue<CrtpPacket> mmQueue;

        ReceiveThread(DatagramSocket socket) {
            mmSocket = socket;
        }

        void setPacketQueue(BlockingQueue<CrtpPacket> queue) {
            mmQueue = queue;
        }

        @Override
        public void run() {
            byte[] buf = new byte[1024];
            DatagramPacket udpPacket = new DatagramPacket(buf, buf.length);
            while (!mmSocket.isClosed() && !isInterrupted()) {
                try {
                    mmSocket.receive(udpPacket);
                    Log.w(TAG, "run: ReceiveData");
                    byte[] raw = udpPacket.getData();
                    byte[] data = new byte[udpPacket.getLength() - 1];
                    System.arraycopy(udpPacket.getData(), udpPacket.getOffset(), data, 0, data.length);
                    int checksum = 0;
                    for (byte b : data) {
                        checksum += (b & 0xff);
                    }
                    if (raw[udpPacket.getLength() - 1] != (byte)checksum) {
                        Log.w(TAG, "Receive Invalid packet");
                        continue;
                    }
                    CrtpPacket packet = new CrtpPacket(data);
                    if (mmQueue != null) {
                        mmQueue.add(packet);
                    }
                } catch (IOException e) {
                    Log.w(TAG, "receivePacket: IOException: " + e.getMessage());
                    mmSocket.close();
                    break;
                }
            }

            Log.d(TAG, "run: ReceiveThread End");
        }
    }
}
