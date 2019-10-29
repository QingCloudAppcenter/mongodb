package com.qingcloud.appcenter.mongodb;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.domain.PageRequest;

import java.util.List;
import java.util.stream.IntStream;

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
        IntStream.range(0, 0x100000).forEach(i -> {
            try {
                String name = String.format("product-%05d", i);
                String version = String.format("v1.0.%d", i % 10);
                Product product = new Product(name, version);
                repository.save(product);
                List<String> result = repository.findByNameAndVersion(name, version, PageRequest.of(0, 10))
                        .map(Product::toString).toList();
                logger.info("Processed: {}", result);
            }
            catch (Exception e) {
                logger.error("Exception occurred at iteration '{}': ", i, e);
            }
        });
    }

}