package com.qingcloud.appcenter.mongodb;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;

@SpringBootApplication
public class MongoDemoApp implements CommandLineRunner {
    private Logger logger = LoggerFactory.getLogger(getClass());

    @Autowired
    ProductRepository repository;

    public static void main(String[] args) {
        SpringApplication.run(MongoDemoApp.class, args);
    }

    @Override
    public void run(String... args) throws Exception {
        Page<Product> result = repository.findAll(PageRequest.of(0, 100));
        logger.info("Found products: {}.", result.map(Product::getName).toList());
    }

}