package com.qingcloud.appcenter.mongodb;

import org.springframework.data.annotation.Id;

public class Product {
    @Id
    private String id;

    private String name;
    private String version;

    public Product(String name, String version) {
        this.name = name;
        this.version = version;
    }

    @Override
    public String toString() {
        return String.format("Product[id=%s, name='%s', version='%s']", id, name, version);
    }
}
