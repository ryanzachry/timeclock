package com.company.tcterminal;


import android.content.Context;
import android.os.AsyncTask;

public class Checker extends AsyncTask<Boolean, Void, Boolean> {

    private Context context;

    public Checker(Context context) {
        this.context = context;
    }

    @Override
    protected void onPreExecute() {

    }


    @Override
    protected Boolean doInBackground(Boolean... b) {

        return false;
    }


    @Override
    protected void onPostExecute(Boolean res) {

    }


}
