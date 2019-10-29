package com.qingcloud.appcenter.mongodb;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.repository.Repository;

public interface ProductRepository extends Repository<Product, Long> {
    Page<Product> findAll(Pageable pageable);

    Product findByNameAndVersionAllIgnoringCase(String name, String version);
}
