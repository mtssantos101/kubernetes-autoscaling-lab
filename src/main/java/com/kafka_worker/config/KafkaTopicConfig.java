package com.kafka_worker.config;

import org.apache.kafka.clients.admin.NewTopic;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;

@Configuration
public class KafkaTopicConfig {
    @Bean
    public NewTopic messageCreatedTopic() {
        return TopicBuilder.name("message.sended")
                .partitions(1)
                .replicas(1)
                .build();
    }
}
