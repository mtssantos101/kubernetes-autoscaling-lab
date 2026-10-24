package com.kafka_worker.messaging;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

@Service
public class MessageProducer {
    private static final String TOPIC = "message.sended";

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final Counter published;
    private final Counter publishErrors;

    public MessageProducer(
            KafkaTemplate<String, String> kafkaTemplate,
            MeterRegistry registry) {
        this.kafkaTemplate = kafkaTemplate;
        this.published = registry.counter("kafka.messages.published", "topic", TOPIC);
        this.publishErrors = registry.counter("kafka.messages.publish.errors", "topic", TOPIC);
    }

    public void publish(String messageId) {
        kafkaTemplate.send(TOPIC, messageId)
                .whenComplete((result, exception) -> {
                    if (exception != null) {
                        publishErrors.increment();
                        System.err.println("Erro ao publicar mensagem: " + exception.getMessage());
                        return;
                    }

                    published.increment();
                    System.out.println("Mensagem publicada: "
                            + result.getRecordMetadata().offset());
                });
    }
}