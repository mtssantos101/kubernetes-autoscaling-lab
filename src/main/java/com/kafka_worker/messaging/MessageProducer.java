package com.kafka_worker.messaging;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

@Service
public class MessageProducer {
    private static final Logger logger = LoggerFactory.getLogger(MessageProducer.class);
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
                        logger.error("Falha ao publicar mensagem no tópico {}", TOPIC, exception);
                        return;
                    }

                    published.increment();
                    logger.info("Mensagem publicada no tópico {}, partição {}, offset {}",
                            TOPIC,
                            result.getRecordMetadata().partition(),
                            result.getRecordMetadata().offset());
                });
    }
}
