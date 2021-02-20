package com.qingcloud.appcenter.mongodb;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.repository.Repository;

public interface ProductRepository extends Repository<Product, String> {
    Product save(Product product);

    Page<Product> findAll(Pageable pageable);

    Page<Product> findByNameAndVersion(String name, String version, Pageable pageable);
}
