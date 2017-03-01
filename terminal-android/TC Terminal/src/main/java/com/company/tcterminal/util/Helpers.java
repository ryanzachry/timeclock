package com.company.tcterminal.util;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.os.Environment;
import android.provider.Settings;

import org.apache.http.HttpEntity;
import org.apache.http.HttpResponse;
import org.apache.http.client.methods.HttpGet;
import org.apache.http.client.methods.HttpPost;
import org.apache.http.impl.client.DefaultHttpClient;
import org.apache.http.params.BasicHttpParams;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.URL;
import java.net.URLConnection;

public class Helpers {
    private Context c;

    public Helpers() { }
    public Helpers(Context context) {
        c = context;
    }


    private String makeUserAgent() {
        // We want to provide some id for the server, adding a header requires overriding each
        // request which proved to be not worth it. Setting the user agent will work
        String ua = "Company TC-Terminal: ";
        try {
            PackageInfo info = c.getPackageManager().getPackageInfo(c.getPackageName(), 0);
            final String appVersion = info.versionName + "." + info.versionCode;
            final String androidID = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.ANDROID_ID);
            ua = ua + "[ id:"+androidID+" version:"+appVersion+" ]";
        } catch (Exception e) {
            ua = ua + "[ ]";
        }

        return ua;
    }

    /**
     *
     *
     * @param url
     * @param saveFile
     * @return
     */
    public boolean mirrorFile(String url, String saveFile) {
        DefaultHttpClient httpClient = new DefaultHttpClient(new BasicHttpParams());
        HttpGet httpGet = new HttpGet(url);
        httpGet.setHeader("User-Agent", makeUserAgent());

        try {
            HttpResponse response = httpClient.execute(httpGet);
            HttpEntity entity = response.getEntity();

            InputStream in = entity.getContent();
            OutputStream out = new FileOutputStream(saveFile);
            byte data[] = new byte[1024];
            int count;
            while ((count = in.read(data)) != -1) {
                out.write(data, 0, count);
            }
            out.flush();
            out.close();
            in.close();
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }

        return true;
    }

    /**
     *
     *
     * @param url
     * @return
     */
    public JSONObject fetchJSON(String url) {
        DefaultHttpClient httpClient = new DefaultHttpClient(new BasicHttpParams());
        HttpGet httpGet = new HttpGet(url);
        httpGet.setHeader("User-Agent", makeUserAgent());
        httpGet.setHeader("Content-type", "application/json");

        InputStream in = null;
        String result = null;
        try {
            HttpResponse response = httpClient.execute(httpGet);
            HttpEntity entity = response.getEntity();
            in = entity.getContent();

            BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"), 8);
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line + '\n');
            }
            result = sb.toString();

        } catch (Exception e) {
            e.printStackTrace();
        }
        finally {
            try {
                if (in != null) in.close();
            } catch (Exception squish) { /**/ }
        }

        try {
            return new JSONObject(result);
        } catch (Exception e) { /**/ }

        return null;
    }

}
