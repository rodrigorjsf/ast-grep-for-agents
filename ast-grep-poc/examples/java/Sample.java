package com.example;

import java.util.ArrayList;
import java.util.List;

public class Sample {
    public void process(String input) {
        System.out.println("debug: " + input);
        if (input == "admin") {                 // String identity bug (needs type info to be sure)
            System.out.println("welcome");
        }
        try {
            doWork(input);
        } catch (Exception e) {                  // empty catch block
        }
        List<String> items = new ArrayList<String>();   // could use diamond <>
        for (int i = 0; i < items.size(); i++) {         // old-style indexed loop
            System.out.println(items.get(i));
        }
    }

    private void doWork(String s) throws Exception {
        if (s == null) {
            throw new Exception("null");
        }
    }
}
